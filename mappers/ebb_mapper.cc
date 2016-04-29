/* Copyright 2015 Stanford University
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */


#include <map>
#include <set>

#include "default_mapper.h"
#include "legion_c_util.h"
#include "serialize.h"
#include "utilities.h"

#include "ebb_mapper.h"

using namespace Legion;
using namespace Legion::Mapping;

using LegionRuntime::ImmovableLock;

// legion logger
static LegionRuntime::Logger::Category log_mapper("mapper");

// message types
enum MapperMessageType {
  MAPPER_RECORD_FIELD,
  MAPPER_TOTAL_MESSAGES
};

class AutoImmovableLock {
public:
  AutoImmovableLock(ImmovableLock& _lock)
    : lock(_lock)
  {
    lock.lock();
  }

  ~AutoImmovableLock(void)
  {
    lock.unlock();
  }

protected:
  ImmovableLock& lock;
};

class EbbMapper : public DefaultMapper {
public:
  EbbMapper(Machine machine, Processor local,
            const char *mapper_name = NULL);
  virtual void select_task_options(const MapperContext ctx,
                                   const Task& task,
                                   TaskOptions& output);
  virtual void map_task(const MapperContext ctx,
                        const Task& task,
                        const MapTaskInput& input,
                        MapTaskOutput& output);
  virtual Processor default_policy_select_initial_processor(
                                    MapperContext ctx, const Task &task);
  virtual void default_policy_select_target_processors(
                                    MapperContext ctx,
                                    const Task &task,
                                    std::vector<Processor> &target_procs);
  virtual LogicalRegion default_policy_select_instance_region(
                                    MapperContext ctx, Memory target_memory,
                                    const RegionRequirement &req,
                                    const LayoutConstraintSet &constraints,
                                    bool force_new_instances,
                                    bool meets_constraints);
  virtual void default_policy_select_constraint_fields(
                                    MapperContext ctx,
                                    const RegionRequirement &req,
                                    std::vector<FieldID> &fields);
  virtual bool default_policy_select_close_virtual(const MapperContext ctx,
                                                   const Close &close);
  virtual void handle_message(const MapperContext ctx,
                              const MapperMessage& message);

  void add_field(FieldSpace fs, FieldID fid);
private:
  // active fields for a logical region
  std::map<FieldSpace, std::set<FieldID> >   active_fields;
  ImmovableLock active_fields_lock;

  // instance cache
  std::map<Memory, std::map<LogicalRegion, std::pair<Legion::Mapping::PhysicalInstance, LayoutConstraintID> > > cached_instances;

  // cached values from the machine model
  std::vector<Processor>                      all_procs;
  int                                         n_nodes;
  int                                         per_node;
  // helper for creating regions
  bool make_instance(MapperContext ctx,
                     Memory target_memory,
                     const RegionRequirement &req,
                     LayoutConstraintSet constraints,
                     Legion::Mapping::PhysicalInstance &result);
  // get logical region corresponding to a region requirement
  LogicalRegion get_root_region(MapperContext ctx,
                                   const RegionRequirement &req);
  LogicalRegion get_root_region(MapperContext ctx,
                                const LogicalRegion &handle);
  LogicalRegion get_root_region(MapperContext ctx,
                                const LogicalPartition &handle);
};  // class EbbMapper

// EbbMapper constructor
EbbMapper::EbbMapper(Machine machine, Processor local,
                     const char *mapper_name)
  : DefaultMapper(machine, local, mapper_name)
  , active_fields_lock(true)
{
  Machine::ProcessorQuery query_all_procs =
        Machine::ProcessorQuery(machine).only_kind(Processor::LOC_PROC);
  all_procs.insert(all_procs.begin(),
                   query_all_procs.begin(),
                   query_all_procs.end());
  n_nodes = 0;
  for(int i=0; i<all_procs.size(); i++) {
    if (all_procs[i].address_space() >= n_nodes) {
      n_nodes = all_procs[i].address_space() + 1;
    }
  }
  per_node = all_procs.size() / n_nodes;

  //if (local.id == all_procs[0].id) {
  //  printf("Hello from mapper\n");
  //  for(int i=0; i<all_procs.size(); i++)
  //    printf(" PROC %d %llx %d %u\n", i, all_procs[i].id,
  //                                 all_procs[i].kind(),
  //                                 all_procs[i].address_space());
  //}
}

void EbbMapper::select_task_options(const MapperContext ctx,
                                    const Task& task,
                                    TaskOptions& output) {
  // Select an initial processor, BUT if it is a local processor, keep
  // self instead.
  output.initial_proc = default_policy_select_initial_processor(ctx, task);
  if (output.initial_proc.address_space() == local_proc.address_space()) {
    output.initial_proc = local_proc;
  }

  output.inline_task = false;
  output.stealable = stealing_enabled; 
  output.map_locally = true;
}


void EbbMapper::map_task(const MapperContext ctx,
                         const Task& task,
                         const MapTaskInput& input,
                         MapTaskOutput& output) {
  ////////////////////////////////////////////////////////////////////
  /// 1. Select the target processors to run on and other
  ///    miscellaneous flags. This is copy-and-paste from the default
  ///    mapper and shouldn't need to be changed.
  ////////////////////////////////////////////////////////////////////

  log_mapper.spew("Default map_task in %s", get_mapper_name());
  Processor::Kind target_kind = task.target_proc.kind();
  // Get the variant that we are going to use to map this task
  VariantInfo chosen = find_preferred_variant(task, ctx,
                    true/*needs tight bound*/, true/*cache*/, target_kind);
  output.chosen_variant = chosen.variant;
  // TODO: some criticality analysis to assign priorities
  output.task_priority = 0;
  output.postmap_task = false;
  // Figure out our target processors
  default_policy_select_target_processors(ctx, task, output.target_procs);
  assert(!output.target_procs.empty());
  Processor target_proc = *output.target_procs.begin();

  ////////////////////////////////////////////////////////////////////
  /// 2. Select the instances for each region requirement. Instead of
  ///    caching the whole task (as in the default mapper), cache each
  ///    region individual. Each region will get one and only one
  ///    instance. If constraints change in an incompatible way,
  ///    re-create this instance.
  ////////////////////////////////////////////////////////////////////

  const TaskLayoutConstraintSet &layout_constraints = 
    mapper_rt_find_task_layout_constraints(ctx, 
                          task.task_id, output.chosen_variant);

  Memory target_memory =
    default_policy_select_target_memory(ctx, target_proc);
  for (unsigned idx = 0; idx < task.regions.size(); idx++) {
    const RegionRequirement &req = task.regions[idx];

    // Skip any empty regions
    if ((req.privilege == NO_ACCESS) ||
        (req.privilege_fields.empty())) {
      continue;
    }

    // Otherwise make a normal instance for the given region
    LayoutConstraintSet constraints;
    if (req.privilege == REDUCE) {
      std::vector<FieldID> fields(req.privilege_fields.begin(),
                                  req.privilege_fields.end());
      std::vector<DimensionKind> dimension_ordering(4);
      dimension_ordering[0] = DIM_X;
      dimension_ordering[1] = DIM_Y;
      dimension_ordering[2] = DIM_Z;
      dimension_ordering[3] = DIM_F;
      constraints.add_constraint(SpecializedConstraint(
            SpecializedConstraint::REDUCTION_FOLD_SPECIALIZE, req.redop))
        .add_constraint(MemoryConstraint(target_memory.kind()))
        .add_constraint(FieldConstraint(fields, false/*contiguous*/,
                                        false/*inorder*/))
        // .add_constraint(OrderingConstraint(dimension_ordering, 
        //                                    false/*contigous*/))
        ;
    } else {
      // Normal instance creation
      std::vector<FieldID> fields;
      default_policy_select_constraint_fields(ctx, req, fields);
      std::vector<DimensionKind> dimension_ordering(4);
      dimension_ordering[0] = DIM_X;
      dimension_ordering[1] = DIM_Y;
      dimension_ordering[2] = DIM_Z;
      dimension_ordering[3] = DIM_F;
      // Our base default mapper will try to make instances of containing
      // all fields (in any order) laid out in SOA format to encourage 
      // maximum re-use by any tasks which use subsets of the fields
      constraints.add_constraint(SpecializedConstraint())
        .add_constraint(MemoryConstraint(target_memory.kind()))
        .add_constraint(FieldConstraint(fields, false/*contiguous*/,
                                        false/*inorder*/))
        .add_constraint(OrderingConstraint(dimension_ordering, 
                                           false/*contigous*/));
    }

    output.chosen_instances[idx].resize(output.chosen_instances[idx].size() + 1);
    if (!make_instance(ctx, target_memory, req,
                       constraints, output.chosen_instances[idx].back())) {
      default_report_failed_instance_creation(task, idx,
                                  target_proc, target_memory);
    }

    assert(mapper_rt_acquire_instances(ctx, output.chosen_instances[idx]));
  }

}

Processor EbbMapper::default_policy_select_initial_processor(
                                    MapperContext ctx, const Task &task) {
  if (false && task.tag != 0) {
    // all_procs here is a safety modulus
    int proc_num = (task.tag - 1)%all_procs.size();
    Processor p = all_procs[proc_num];
    //printf("Launching Tagged on %llx %lx\n", p.id, task.tag);
    return p;
  } else if (!task.regions.empty() &&
             task.regions[0].handle_type == SINGULAR) {
    Color index = mapper_rt_get_logical_region_color(ctx, task.regions[0].region);
    int proc_off = (int(index) / n_nodes)%per_node;
    int node_off = int(index) % n_nodes;
    // all_procs here is a safety modulus
    int proc_num = (node_off*per_node + proc_off)%all_procs.size();
    Processor p = all_procs[proc_num];
    //printf("Launching Tagless on %llx %lx\n", p.id, task.tag);
    return p;
  }
  return DefaultMapper::default_policy_select_initial_processor(ctx, task);
}

void EbbMapper::default_policy_select_target_processors(
                                    MapperContext ctx,
                                    const Task &task,
                                    std::vector<Processor> &target_procs) {
  target_procs.push_back(
    EbbMapper::default_policy_select_initial_processor(ctx, task));
}

LogicalRegion EbbMapper::default_policy_select_instance_region(
                                    MapperContext ctx, Memory target_memory,
                                    const RegionRequirement &req,
                                    const LayoutConstraintSet &constraints,
                                    bool force_new_instances,
                                    bool meets_constraints) {
  // One one node, build a large instance; otherwise build smaller instances.
  LogicalRegion result = req.region;
  if (!meets_constraints || (req.privilege == REDUCE))
    return result;
  if (total_nodes == 1)
  {
    while (mapper_rt_has_parent_logical_partition(ctx, result))
    {
      LogicalPartition parent =
        mapper_rt_get_parent_logical_partition(ctx, result);
      result = mapper_rt_get_parent_logical_region(ctx, parent);
    }
    return result;
  }
  else
    return result;
}

bool EbbMapper::make_instance(MapperContext ctx,
                              Memory target_memory,
                              const RegionRequirement &req,
                              LayoutConstraintSet constraints,
                              Legion::Mapping::PhysicalInstance &result)
{
  std::map<LogicalRegion, std::pair<Legion::Mapping::PhysicalInstance, LayoutConstraintID> > &cache = cached_instances[target_memory];

  LogicalRegion target_region = req.region;
  if (mapper_rt_has_parent_logical_partition(ctx, target_region)) {
    LogicalPartition part =
      mapper_rt_get_parent_logical_partition(ctx, target_region);
    LogicalRegion parent = mapper_rt_get_parent_logical_region(ctx, part);

    if (mapper_rt_has_parent_logical_partition(ctx, parent)) {
      Color color = mapper_rt_get_logical_region_color(ctx, target_region);
      const Color MIDDLE = 13; // 9 + 5 - 1 == color of middle ghost region
      if (color == MIDDLE) {
        target_region = parent;
      }
    }
  }

  std::map<LogicalRegion, std::pair<Legion::Mapping::PhysicalInstance,
                                    LayoutConstraintID> >::iterator
    finder = cache.find(target_region);
  if (req.privilege != REDUCE && finder != cache.end()) {
    if (true /* mapper_rt_do_constraints_entail(ctx, finder->second.second, layout) */) {
      result = finder->second.first;
      return true;
    } else {
      assert(false && "recycling cached instance");
      mapper_rt_set_garbage_collection_priority(ctx, finder->second.first, GC_FIRST_PRIORITY);
    }
  }

  std::vector<LogicalRegion> target_regions(1, target_region);
  if (!mapper_rt_create_physical_instance(ctx, target_memory, constraints,
                                          target_regions, result)) {
    return false;
  }
  int priority = GC_DEFAULT_PRIORITY;
  if (req.privilege == REDUCE) {
    priority = GC_FIRST_PRIORITY;
  } else {
    priority = GC_NEVER_PRIORITY;
    LayoutConstraintID layout = mapper_rt_register_layout(ctx, constraints);
    cache[target_region] =
      std::pair<Legion::Mapping::PhysicalInstance,
                LayoutConstraintID>(result, layout);
  }
  mapper_rt_set_garbage_collection_priority(ctx, result, priority);
  return true;
}

void EbbMapper::default_policy_select_constraint_fields(
                                    MapperContext ctx,
                                    const RegionRequirement &req,
                                    std::vector<FieldID> &fields) {
  FieldSpace fs = req.parent.get_field_space();

  AutoImmovableLock guard(active_fields_lock);
  std::set<FieldID> &active = active_fields[fs];

  // FIXME: Shouldn't be necessary to do this....
  active.insert(req.privilege_fields.begin(), req.privilege_fields.end());

  fields.insert(fields.begin(), active.begin(), active.end());
}

bool EbbMapper::default_policy_select_close_virtual(const MapperContext ctx,
                                                    const Close &close)
{
  return false;
}

void EbbMapper::handle_message(const MapperContext ctx,
                               const MapperMessage& message)
{
  Realm::Serialization::FixedBufferDeserializer buffer(message.message, message.size);
  int msg_type;
  buffer >> msg_type;
  switch(msg_type) {
    //case MAPPER_RECORD_FIELD:
    //{
    //  FieldSpace fs;
    //  buffer >> fs;
    //  FieldID field;
    //  buffer >> field;
    //  AutoImmovableLock guard(active_fields_lock);
    //  active_fields[fs].insert(field);
    //  break;
    //}
    default:
    {
      printf("Invalid message recieved by mapper\n");
      assert(false);
    }
  }
}

void EbbMapper::add_field(FieldSpace fs, FieldID fid)
{
  AutoImmovableLock guard(active_fields_lock);
  std::set<FieldID> &active = active_fields[fs];
  if (active.find(fid) == active.end()) {
    // broadcast and record a new field
    //Realm::Serialization::DynamicBufferSerializer buffer(sizeof(FieldSpace) + sizeof(FieldID));
    //buffer << (int)MAPPER_RECORD_FIELD;
    //buffer << fs;
    //buffer << fid;
    // broadcast_message(buffer.get_buffer(), buffer.bytes_used());
    active.insert(fid);
  }
}

LogicalRegion EbbMapper::get_root_region(MapperContext ctx,
                                            const RegionRequirement &req) {
  LogicalRegion root;
  if (req.handle_type == SINGULAR || req.handle_type == REG_PROJECTION) {
    root = get_root_region(ctx, req.region);
  } else {
    assert(req.handle_type == PART_PROJECTION);
    root = get_root_region(ctx, req.partition);
  }
  return root;
}

LogicalRegion EbbMapper::get_root_region(MapperContext ctx,
                                         const LogicalRegion &handle) {
  if (mapper_rt_has_parent_logical_partition(ctx, handle)) {
    return get_root_region(ctx, mapper_rt_get_parent_logical_partition(ctx, handle));
  }
  return handle;
}

LogicalRegion EbbMapper::get_root_region(MapperContext ctx,
                                         const LogicalPartition &handle) {
  return get_root_region(ctx, mapper_rt_get_parent_logical_region(ctx, handle));
}

static void create_mappers(Machine machine,
                           Runtime *runtime,
                           const std::set<Processor> &local_procs
) {
  for (
    std::set<Processor>::const_iterator it = local_procs.begin();
    it != local_procs.end();
    it++) {
    runtime->replace_default_mapper(
      new EbbMapper(machine, *it, "ebb_mapper"), *it
    );
  }
}

void ebb_mapper_add_field(legion_runtime_t runtime_,
                          legion_context_t ctx_,
                          legion_logical_region_t region_,
                          legion_field_id_t fid) {
  Runtime *runtime = CObjectWrapper::unwrap(runtime_);
  Context ctx = CObjectWrapper::unwrap(ctx_)->context();
  LogicalRegion region = CObjectWrapper::unwrap(region_);

  EbbMapper *mapper = dynamic_cast<EbbMapper *>(runtime->get_mapper(ctx, 0));
  mapper->add_field(region.get_field_space(), fid);
}

void register_ebb_mappers() {
  HighLevelRuntime::set_registration_callback(create_mappers);
}
