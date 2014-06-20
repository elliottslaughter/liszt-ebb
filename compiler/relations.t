
-- file/module namespace table
local R = {}
package.loaded["compiler.relations"] = R

local L = terralib.require "compiler.lisztlib"
local T = terralib.require "compiler.types"
local C = terralib.require "compiler.c"
local DLD = terralib.require "compiler.dld"

local PN = terralib.require "lib.pathname"

local JSON = require('compiler.JSON')

local DynamicArray = terralib.require('compiler.rawdata').DynamicArray



local valid_name_err_msg =
  "must be valid Lua Identifiers: a letter or underscore,"..
  " followed by zero or more underscores, letters, and/or numbers"
L.valid_name_err_msg = {
  relation = "Relation names " .. valid_name_err_msg,
  field    = "Field names " .. valid_name_err_msg,
  subset   = "Subset names " .. valid_name_err_msg
}
function L.is_valid_lua_identifier(name)
  if type(name) ~= 'string' then return false end

  -- regex for valid LUA identifiers
  if not name:match('^[_%a][_%w]*$') then return false end

  return true
end


-------------------------------------------------------------------------------
--[[ LRelation methods                                                     ]]--
-------------------------------------------------------------------------------

function L.NewRelation(size, name)
    -- error check
  if not name or type(name) ~= "string" then
    error("NewRelation() expects a string as the 2nd argument", 2)
  end
  if not L.is_valid_lua_identifier(name) then
    error(L.valid_name_err_msg.relation, 2)
  end

  -- construct and return the relation
  local rel = setmetatable( {
    _concrete_size = size,
    _logical_size  = size,

    _fields    = terralib.newlist(),
    _subsets   = terralib.newlist(),
    _macros    = terralib.newlist(),
    _functions = terralib.newlist(),

    _incoming_refs = {}, -- used for walking reference graph
    _name      = name,
    _typestate = {
      --groupedby   = false, -- use _grouping entry's presence instead
      fragmented  = false,
      --has_subsets = false, -- use #_subsets
    },
  },
  L.LRelation)

  -- create a mask to track which rows are live.
  rawset(rel, '_is_live_mask', L.LField.New(rel, '_is_live_mask', L.bool))
  rel._is_live_mask:Load(true)

  return rel
end

function L.LRelation:Size()
  return self._logical_size
end
function L.LRelation:ConcreteSize()
  return self._concrete_size
end
function L.LRelation:Name()
  return self._name
end

function L.LRelation:ResizeConcrete(new_size)
  if self:isGrouped() then
    error('cannot resize a grouped relation', 2)
  end
  if self:hasSubsets() then
    error('cannot resize a relation with subsets', 2)
  end
  self._is_live_mask.array:resize(new_size)
  for _,field in ipairs(self._fields) do
    field.array:resize(new_size)
  end
  self._concrete_size = new_size
end

function L.LRelation:isFragmented()
  return self._typestate.fragmented
end
function L.LRelation:isCompact()
  return not self._typestate.fragmented
end
function L.LRelation:hasSubsets()
  return #self._subsets ~= 0
end
function L.LRelation:isGrouped()
  return self._grouping ~= nil
end

-- returns a record type
function L.LRelation:StructuralType()
  local rec = {}
  for _, field in ipairs(self._fields) do
    rec[field.name] = field.type
  end
  local typ = L.record(rec)
  return typ
end

-- prevent user from modifying the lua table
function L.LRelation:__newindex(fieldname,value)
  error("Cannot assign members to LRelation object "..
      "(did you mean to call relation:New...?)", 2)
end


function L.LRelation:NewFieldMacro (name, macro)
  if not name or type(name) ~= "string" then
    error("NewFieldMacro() expects a string as the first argument", 2)
  end
  if not L.is_valid_lua_identifier(name) then
    error(L.valid_name_err_msg.field, 2)
  end
  if self[name] then
    error("Cannot create a new field-macro with name '"..name.."'  "..
          "That name is already being used.", 2)
  end

  if not L.is_macro(macro) then
    error("NewFieldMacro() expects a Macro as the 2nd argument", 2)
  end

  rawset(self, name, macro)
  self._macros:insert(macro)
  return macro
end

function L.LRelation:NewFieldFunction (name, userfunc)
  if not name or type(name) ~= "string" then
    error("NewFieldFunction() expects a string as the first argument", 2)
  end
  if not L.is_valid_lua_identifier(name) then
    error(L.valid_name_err_msg.field, 2)
  end
  if self[name] then
    error("Cannot create a new field-function with name '"..name.."'  "..
          "That name is already being used.", 2)
  end

  if not L.is_user_func(userfunc) then
    error("NewFieldFunction() expects a Liszt Function "..
          "as the 2nd argument", 2)
  end

  rawset(self, name, userfunc)
  self._functions:insert(userfunc)
  return userfunc
end

function L.LRelation:GroupBy(name)
  local key_field = self[name]
  local live_mask = self._is_live_mask
  if self._grouping then
    error("GroupBy(): Relation is already grouped", 2)
  elseif not L.is_field(key_field) then
    error("GroupBy(): Could not find a field named '"..name.."'", 2)
  elseif not key_field.type:isRow() then
    error("GroupBy(): Grouping by non-row-type fields is "..
          "currently prohibited.", 2)
  end

  -- WARNING: The sizing policy will break with dead rows
  if self:isFragmented() then
    error("GroupBy(): Cannot group a fragmented relation", 2)
  end
  if key_field.type.relation:isFragmented() then
    error("GroupBy(): Cannot group by a fragmented relation", 2)
  end

  local num_keys = key_field.type.relation:ConcreteSize() -- # possible keys
  local num_rows = key_field:ConcreteSize()
  rawset(self,'_grouping', {
    key_field = key_field,
    index = L.LIndex.New{
      owner=self,
      processor = L.default_processor,
      name='groupby_'..key_field:Name(),
      size=num_keys+1
    },
  })

  self._grouping.index._array:write_ptr(function(indexdata)
    local prev,pos = 0,0
    key_field.array:read_ptr(function(keyptr)
      for i = 0, num_keys - 1 do
        indexdata[i] = pos
        while keyptr[pos] == i and pos < num_rows do
          if keyptr[pos] < prev then
            self._grouping.index:Release()
            self._grouping = nil
            error("GroupBy(): Key field '"..name.."' is not sorted.")
          end
          prev,pos = keyptr[pos], pos+1
        end
      end
    end) -- key_field read
    assert(pos == num_rows)
    indexdata[num_keys] = pos
  end) -- indexdata write

  -- record reference from this relation to the relation it's grouped by
  key_field.type.relation._incoming_refs[self] = 'group'
end

function L.LRelation:MoveTo( proc )
  if proc ~= L.CPU and proc ~= L.GPU then
    error('must specify valid processor to move to', 2)
  end

  self._is_live_mask:MoveTo(proc)
  for _,f in ipairs(self._fields) do f:MoveTo(proc) end
  for _,s in ipairs(self._subsets) do s:MoveTo(proc) end
  if self._grouping then self._grouping.index:MoveTo(proc) end
end


function L.LRelation:print()
  print(self._name, "size: ".. tostring(self:Size()),
                    "concrete size: "..tostring(self:ConcreteSize()))
  for i,f in ipairs(self._fields) do
    f:print()
  end
end


-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ Insert / Delete                                                       ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

-- returns a useful error message 
function L.LRelation:UnsafeToDelete()
  if self:isGrouped() then
    return 'Cannot delete from relation '..self:Name()..
           ' because it\'s grouped'
  end
  if self:hasSubsets() then
    return 'Cannot delete from relation '..self:Name()..
           ' because it has subsets'
  end
  -- check whether this relation is being referred to by another relation
  local msg = ''
  for ref,kind in pairs(self._incoming_refs) do
    if kind == 'row_field' then
      msg = msg ..
        '\n  it\'s referred to by a field: '..ref:FullName()
    elseif kind == 'group' then
      msg = msg ..
        '\n  it\'s being used to group another relation: '..ref:Name()
    end
  end
  if #msg > 0 then
    return 'Cannot delete from relation '..self:Name()..' because'..msg
  end
end

function L.LRelation:UnsafeToInsert(record_type)
  -- duplicate above checks
  local msg = self:UnsafeToDelete()
  if msg then
    return msg:gsub('delete from','insert into')
  end

  if record_type ~= self:StructuralType() then
    return 'inserted record type does not match relation'
  end
end

-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ Indices:                                                              ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

function L.LIndex.New(params)
  if not L.is_relation(params.owner) or
     type(params.name) ~= 'string' or
     not (params.size or params.data)
  then
    error('bad parameters')
  end

  local index = setmetatable({
    _owner = params.owner,
    _name  = params.name,
  }, L.LIndex)

  index._array = DynamicArray.New {
    size = params.size or (#params.data),
    type = L.addr:terraType(),
    processor = params.processor or L.default_processor,
  }

  if params.data then
    index._array:write_ptr(function(ptr)
      for i=1,#params.data do
        ptr[i-1] = params.data[i]
      end
    end) -- write_ptr
  end

  return index
end

function L.LIndex:DataPtr()
  return self._array:ptr()
end
function L.LIndex:Size()
  return self._array:size()
end

function L.LIndex:Relation()
  return self._owner
end

function L.LIndex:ReAllocate(size)
  self._array:resize(size)
end

function L.LIndex:MoveTo(proc)
  self._array:moveto(proc)
end

function L.LIndex:Release()
  if self._array then
    self._array:free()
    self._array = nil
  end
end

-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ Subsets:                                                              ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

function L.LSubset:Relation()
  return self._owner
end

function L.LSubset:MoveTo( proc )
  if proc ~= L.CPU and proc ~= L.GPU then
    error('must specify valid processor to move to', 2)
  end

  if self._boolmask   then self._boolmask:MoveTo(proc)    end
  if self._index      then self._index:MoveTo(proc)       end
end

function L.LRelation:NewSubsetFromFunction (name, predicate)
  if not name or type(name) ~= "string" then
    error("NewSubsetFromFunction() "..
          "expects a string as the first argument", 2)
  end
  if not L.is_valid_lua_identifier(name) then
    error(L.valid_name_err_msg.subset, 2)
  end
  if self[name] then
    error("Cannot create a new subset with name '"..name.."'  "..
          "That name is already being used.", 2)
  end

  if type(predicate) ~= 'function' then
    error("NewSubsetFromFunction() expects a predicate "..
          "for determining membership as the second argument", 2)
  end

  -- SIMPLIFYING HACK FOR NOW
  if self:isFragmented() then
    error("NewSubsetFromFunction(): Cannot build subsets "..
          "on a fragmented relation", 2)
  end

  -- setup and install the subset object
  local subset = setmetatable({
    _owner    = self,
    _name     = name,
  }, L.LSubset)
  rawset(self, name, subset)
  self._subsets:insert(subset)

  -- NOW WE DECIDE how to encode the subset
  -- we'll try building a mask and decide between using a mask or index
  local SUBSET_CUTOFF_FRAC = 0.1
  local SUBSET_CUTOFF = SUBSET_CUTOFF_FRAC * self:Size()

  local boolmask  = L.LField.New(self, name..'_subset_boolmask', L.bool)
  local index_tbl = {}
  local subset_size = 0
  boolmask:LoadFunction(function(i)
    local val = predicate(i)
    if val then
      table.insert(index_tbl, i)
      subset_size = subset_size + 1
    end
    return val
  end)

  if subset_size > SUBSET_CUTOFF then
  -- USE MASK
    subset._boolmask = boolmask
  else
  -- USE INDEX
    subset._index = L.LIndex.New{
      owner=self,
      name=name..'_subset_index',
      data=index_tbl
    }
    boolmask:ClearData() -- free memory
  end

  return subset
end


-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ Fields:                                                               ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------

-- Client code should never call this constructor
-- For internal use only.  Does not install on relation...
function L.LField.New(rel, name, typ)
  local field   = setmetatable({}, L.LField)
  field.array   = nil
  field.type    = typ
  field.name    = name
  field.owner   = rel
  field:Allocate()

  return field
end

function L.LField:Name()
  return self.name
end
function L.LField:FullName()
  return self.owner._name .. '.' .. self.name
end
function L.LField:Size()
  return self.owner:Size()
end
function L.LField:ConcreteSize()
  return self.owner:ConcreteSize()
end
function L.LField:Type()
  return self.type
end
function L.LField:DataPtr()
  return self.array:ptr()
end
function L.LField:Relation()
  return self.owner
end

function L.LRelation:NewField (name, typ)  
  if not name or type(name) ~= "string" then
    error("NewField() expects a string as the first argument", 2)
  end
  if not L.is_valid_lua_identifier(name) then
    error(L.valid_name_err_msg.field, 2)
  end
  if self[name] then
    error("Cannot create a new field with name '"..name.."'  "..
          "That name is already being used.", 2)
  end
  
  if L.is_relation(typ) then
    typ = L.row(typ)
  end
  if not T.isLisztType(typ) or not typ:isFieldType() then
    error("NewField() expects a Liszt type or "..
          "relation as the 2nd argument", 2)
  end

  if self:isFragmented() then
    error("NewField() cannot be called on a fragmented relation.", 2)
  end

  -- create the field
  local field = L.LField.New(self, name, typ)
  rawset(self, name, field)
  self._fields:insert(field)

  -- record reverse pointers for row-type field references
  if typ:isRow() then
    typ.relation._incoming_refs[field] = 'row_field'
  end

  return field
end

-- TODO: Hide this function so it's not public
function L.LField:Allocate()
  if not self.array then
    self.array = DynamicArray.New{
      size = self:ConcreteSize(),
      type = self:Type():terraType()
    }
  end
end

-- TODO: Hide this function so it's not public
-- remove allocated data and clear any depedent data, such as indices
function L.LField:ClearData ()
  if self.array then
    self.array:free()
    self.array = nil
  end
  -- clear grouping data if set on this field
  if self.owner._grouping and
     self.owner._grouping.key_field == self
  then
    self.owner._grouping.index:Release()
    self.owner._grouping = nil
  end
end

function L.LField:MoveTo( proc )
  if proc ~= L.CPU and proc ~= L.GPU then
    error('must specify valid processor to move to', 2)
  end

  self.array:moveto(proc)
end

function L.LRelation:Swap( f1_name, f2_name )
  local f1 = self[f1_name]
  local f2 = self[f2_name]
  if not L.is_field(f1) then
    error('Could not find a field named "'..f1_name..'"', 2) end
  if not L.is_field(f2) then
    error('Could not find a field named "'..f2_name..'"', 2) end
  if f1.type ~= f2.type then
    error('Cannot Swap() fields of different type', 2)
  end

  local tmp = f1.array
  f1.array = f2.array
  f2.array = tmp
end

function L.LRelation:Copy( p )
  if type(p) ~= 'table' or not p.from or not p.to then
    error("relation:Copy() should be called using the form\n"..
          "  relation:Copy{from='f1',to='f2'}", 2)
  end
  local from = self[p.from]
  local to   = self[p.to]
  if not L.is_field(from) then
    error('Could not find a field named "'..p.from..'"', 2) end
  if not L.is_field(to) then
    error('Could not find a field named "'..p.to..'"', 2) end
  if from.type ~= to.type then
    error('Cannot Copy() fields of different type', 2)
  end

  if not from.array then
    error('Cannot Copy() from field with no data', 2) end
  if not to.array then
    to:Allocate()
  end

  to.array:copy(from.array)
end


-- convert lua tables or LVectors to
-- Terra structs used to represent vectors
local function convert_vec(vec_val, typ)
  if L.is_vector(vec_val) then
    -- re-route to the common handler for Lua tables...
    return convert_vec(vec_val.data, typ)
  elseif type(vec_val) == 'table' and #vec_val == typ.N then
    return terralib.new(typ:terraType(), {vec_val})
  else
    return nil
  end
end

function L.LField:LoadFunction(lua_callback)
  if self.owner:isFragmented() then
    error('cannot load into fragmented relation', 2)
  end
  self:Allocate()

  -- NEEDS REVISION FOR CASE OF FRAGMENTATION
  self.array:write_ptr(function(dataptr)
    if self.type:isVector() then
      for i = 0, self:Size() - 1 do
        local val = lua_callback(i)
        dataptr[i] = convert_vec(val, self.type)
      end
    else
      for i = 0, self:Size() - 1 do
        dataptr[i] = lua_callback(i)
      end
    end
  end) -- write_ptr
end

function L.LField:LoadList(tbl)
  if self.owner:isFragmented() then
    error('cannot load into fragmented relation', 2)
  end
  if type(tbl) ~= 'table' then
    error('bad type passed to LoadList().  Expecting a table', 2)
  end
  if #tbl ~= self:Size() then
    error('argument array has the wrong number of elements: '..
          tostring(#tbl)..
          ' (was expecting '..tostring(self:Size())..')', 2)
  end
  self:LoadFunction(function(i)
    return tbl[i+1]
  end)
end

-- TODO: Hide this function so it's not public  (maybe not?)
function L.LField:LoadFromMemory(mem)
  if self.owner:isFragmented() then
    error('cannot load into fragmented relation', 2)
  end
  self:Allocate()

  -- NEEDS REVISION FOR CASE OF FRAGMENTATION

  -- avoid extra copies by wrapping and using the standard copy
  local wrapped = DynamicArray.Wrap{
    size = self:ConcreteSize(),
    type = self.type:terraType(),
    data = mem,
    processor = L.CPU,
  }
  self.array:copy(wrapped)
end

function L.LField:LoadConstant(constant)
  if self.owner:isFragmented() then
    error('cannot load into fragmented relation', 2)
  end
  self:Allocate()
  if self.type:isVector() then
    constant = convert_vec(constant, self.type)
  end

  self.array:write_ptr(function(dataptr)
    for i = 0, self:ConcreteSize() - 1 do
      dataptr[i] = constant
    end
  end) -- write_ptr
end

-- generic dispatch function for loads
function L.LField:Load(arg)
  if self.owner:isFragmented() then
    error('cannot load into fragmented relation', 2)
  end
  -- load from lua callback
  if      type(arg) == 'function' then
    return self:LoadFunction(arg)
  elseif  type(arg) == 'cdata' then
    local typ = terralib.typeof(arg)
    if typ and typ:ispointer() then
      return self:LoadFromMemory(arg)
    end
  elseif  type(arg) == 'string' or PN.is_pathname(arg) then
    return self:LoadFromFile(arg)
  elseif  type(arg) == 'table' and not L.is_vector(arg) then
    if self.type:isVector() and #arg == self.type.N then
      return self:LoadConstant(arg)
    else
      return self:LoadList(arg)
    end
  end
  -- default to trying to load as a constant
  return self:LoadConstant(arg)
end



-- convert lua tables or LVectors to
-- Terra structs used to represent vectors
local function terraval_to_lua(val, typ)
  if typ:isVector() then
    local vec = {}
    for i = 1, typ.N do
      vec[i] = terraval_to_lua(val.d[i-1], typ:baseType())
    end
    return vec
  elseif typ:isNumeric() then
    return tonumber(val)
  elseif typ:isLogical() then
    if tonumber(val) == 0 then return false else return true end
  else
    error('unhandled terra_to_lua conversion')
  end
end

function L.LField:DumpToList()
  if self.owner:isFragmented() then
    error('cannot dump from fragmented relation', 2)
  end
  local arr = {}
  self.array:read_ptr(function(dataptr)
    for i = 0, self:ConcreteSize()-1 do
      arr[i+1] = terraval_to_lua(dataptr[i], self.type)
    end
  end) -- read_ptr
  return arr
end

-- callback(i, val)
--      i:      which row we're outputting (starting at 0)
--      val:    the value of this field for the ith row
function L.LField:DumpFunction(lua_callback)
  if self.owner:isFragmented() then
    error('cannot dump from fragmented relation', 2)
  end
  self.array:read_ptr(function(dataptr)
    for i = 0, self:ConcreteSize()-1 do
      local val = terraval_to_lua(dataptr[i], self.type)
      lua_callback(i, val)
    end
  end) -- read_ptr
end

function L.LField:print()
  print(self.name..": <" .. tostring(self.type:terraType()) .. '>')
  if not self.array then
    print("...not initialized")
    return
  else
    print("  . == live  x == dead")
  end

  local N = self.owner:ConcreteSize()
  local livemask = self.owner._is_live_mask

  livemask.array:read_ptr(function(liveptr)
  self.array:read_ptr(function(dataptr)
    local alive
    if (self.type:isVector()) then
      for i = 0, N-1 do
        if liveptr[i] then alive = ' .'
        else                alive = ' x' end
        local s = ''
        for j = 0, self.type.N-1 do
          local t = tostring(dataptr[i].d[j]):gsub('ULL','')
          s = s .. t .. ' '
        end
        print("", tostring(i) .. alive, s)
      end
    else
      for i = 0, N-1 do
        if liveptr[i] then alive = ' .'
        else                alive = ' x' end
        local t = tostring(dataptr[i]):gsub('ULL', '')
        print("", tostring(i) .. alive, t)
      end
    end
  end) -- dataptr
  end) -- liveptr
end


-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--[[ Data Sharing Hooks                                                    ]]--
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------


function L.LField:getDLD()
  if self.owner:isFragmented() then
    error('cannot get DLD from fragmented relation', 2)
  end
  if not self.type:isPrimitive() and not self.type:isVector() then
    error('Can only return DLDs for primitives and vectors, '..
        'not Row types or other types given to fields')
  end

  local terra_type = self.type:terraType()
  local n = nil
  if self.type:isVector() then
    terra_type = self.type:terraBaseType()
    n = self.type.N
  end
  local dld = DLD.new({
    type            = terra_type,
    type_n          = n,
    logical_size    = self.owner:ConcreteSize(),
    data            = self:DataPtr(),
    compact         = true,
  })
  return dld
end









