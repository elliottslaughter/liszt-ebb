local GPU = {}
package.loaded['compiler.gpu_util'] = GPU
local C   = require 'compiler.c'

if not terralib.cudacompile then return end

--[[-----------------------------------------------------------------------]]--
--[[ Thread/Grid/Block                                                     ]]--
--[[-----------------------------------------------------------------------]]--
local tid_x   = cudalib.nvvm_read_ptx_sreg_tid_x
local tid_y   = cudalib.nvvm_read_ptx_sreg_tid_y
local tid_z   = cudalib.nvvm_read_ptx_sreg_tid_z

local b_dim_x = cudalib.nvvm_read_ptx_sreg_ntid_x
local b_dim_y = cudalib.nvvm_read_ptx_sreg_ntid_y
local b_dim_z = cudalib.nvvm_read_ptx_sreg_ntid_z

local bid_x   = cudalib.nvvm_read_ptx_sreg_ctaid_x
local bid_y   = cudalib.nvvm_read_ptx_sreg_ctaid_y
local bid_z   = cudalib.nvvm_read_ptx_sreg_ctaid_z

local g_dim_x = cudalib.nvvm_read_ptx_sreg_nctaid_x
local g_dim_y = cudalib.nvvm_read_ptx_sreg_nctaid_y
local g_dim_z = cudalib.nvvm_read_ptx_sreg_nctaid_z

local thread_id = macro(function()
  return `(tid_x() +
           tid_y() * b_dim_x() +
           tid_z() * b_dim_x() * b_dim_y())
end)

local block_id = macro(function()
  return `(bid_x() +
           bid_y() * g_dim_x() + 
           bid_z() * g_dim_x() * g_dim_y())
end)

local num_blocks = macro(function()
  return `(g_dim_x()*g_dim_y()*g_dim_z())
end)

local global_tid = macro(function()
  return `(thread_id()+block_id()*num_blocks())
end)

local terra get_grid_dimensions(
  num_blocks : uint64,
  max_grid_dim : uint64
) : {uint, uint, uint}
  if num_blocks < max_grid_dim then
    return { num_blocks, 1, 1 }
  elseif num_blocks / max_grid_dim < max_grid_dim then
    return { max_grid_dim,
             (num_blocks + max_grid_dim - 1) / max_grid_dim,
             1 }
  else
    return { max_grid_dim,
             max_grid_dim,
             (num_blocks - 1) / max_grid_dim / max_grid_dim + 1 }
  end
end


--[[-----------------------------------------------------------------------]]--
--[[ Print                                                                 ]]--
--[[-----------------------------------------------------------------------]]--
local vprintf = terralib.externfunction("cudart:vprintf", {&int8,&int8} -> int)
local function createbuffer(args)
  local Buf = terralib.types.newstruct()
  return quote
    var buf : Buf
    escape
      for i,e in ipairs(args) do
        local typ = e:gettype()
        local field = "_"..tonumber(i)
        typ = typ == float and double or typ
        table.insert(Buf.entries,{field,typ})
        emit quote
          buf.[field] = e
        end
      end
    end
  in
    [&int8](&buf)
  end
end

local printf = macro(function(fmt,...)
  local buf = createbuffer({...})
  return `vprintf(fmt,buf) 
end)


--[[-----------------------------------------------------------------------]]--
--[[ Math                                                                  ]]--
--[[-----------------------------------------------------------------------]]--
-- link the bitcode for libdevice so that we can access device math functions
-- CUDA libdevice has all the math functions:
-- http://docs.nvidia.com/cuda/libdevice-users-guide/#axzz3CND85k3B
local cuda_success, cuda_version =
  pcall(function() return cudalib.localversion() end)
cuda_version = cuda_success and cuda_version or 30

local libdevice = terralib.cudahome..
  string.format("/nvvm/libdevice/libdevice.compute_%d.10.bc",cuda_version)
terralib.linklibrary(libdevice)

local cbrt = terralib.externfunction("__nv_cbrt", double -> double)
local cos  = terralib.externfunction("__nv_cos",  double -> double)
local acos = terralib.externfunction("__nv_acos", double -> double)
local sin  = terralib.externfunction("__nv_sin",  double -> double)
local asin = terralib.externfunction("__nv_asin", double -> double)
local tan  = terralib.externfunction("__nv_tan",  double -> double)
local atan = terralib.externfunction("__nv_atan", double -> double)
local log  = terralib.externfunction("__nv_log",  double -> double)
local pow  = terralib.externfunction("__nv_pow",  {double, double} -> double)
local fmod = terralib.externfunction("__nv_fmod", {double, double} -> double)


--[[-----------------------------------------------------------------------]]--
--[[ Atomic reductions                                                     ]]--
--[[-----------------------------------------------------------------------]]--
local reduce_max_int32 = macro(function(result_ptr, val)
  return terralib.asm(terralib.types.unit,
    "red.global.max.u32 [$0], $1;","l,r",true,result_ptr,val)
end)

local reduce_min_int32 = macro(function(result_ptr, val)
  return terralib.asm(terralib.types.unit,
    "red.global.min.u32 [$0], $1;","l,r",true,result_ptr,val)
end)

local reduce_add_int32 = macro(function(result_ptr, val)
  return terralib.asm(terralib.types.unit,
    "red.global.add.u32 [$0], $1;","l,r",true,result_ptr,val)
end)

local reduce_and_b32 = macro(function(result_ptr, val)
  return terralib.asm(terralib.types.unit,
    "red.global.and.b32 [$0], $1;","l,r",true,result_ptr,val)
end)

local reduce_or_b32 = macro(function(result_ptr, val)
  return terralib.asm(terralib.types.unit,
    "red.global.or.b32 [$0], $1;","l,r",true,result_ptr,val)
end)

local atomic_add_float =
  terralib.intrinsic("llvm.nvvm.atomic.load.add.f32.p0f32",
                     {&float,float} -> {float})


--[[-----------------------------------------------------------------------]]--
--[[ Implementation of slow atomics                                        ]]--
--[[-----------------------------------------------------------------------]]--
local cas_uint64 = terra(address : &uint64, compare : uint64, value : uint64)
  return terralib.asm(terralib.types.uint64,
    "atom.global.cas.b64 $0, [$1], $2, $3;",
    "=l,l,l,l",true,address,compare,value)
end

local cas_uint32 = terra(address : &uint32, compare : uint32, value : uint32)
  var old : uint32 = @address
  terralib.asm(terralib.types.uint32,
    "atom.global.cas.32 $0, [$1], $2, $3;",
    "r,l,r,r",true,old,address,compare,value)
  return old
end

local function generate_slow_atomic_64 (op, typ)
  return terra (address : &typ, operand : typ)
    var old : typ = @address
    var assumed : typ
    var new     : typ

    var new_b     : &uint64 = [&uint64](&new)
    var assumed_b : &uint64 = [&uint64](&assumed)
    var res       :  uint64

    var mask = false
    repeat
      if not mask then
        assumed = old
        new     = op(assumed,operand)
        res     = cas_uint64([&uint64](address), @assumed_b, @new_b)
        old     = @[&typ](&res)
        mask    = assumed == old
      end
    until mask
  end
end

local function generate_slow_atomic_32 (op, typ)
  return terra (address : &typ, operand : typ)
    var old : typ = @address
    var assumed   : typ
    var new       : typ

    var new_b     : &uint32 = [&uint32](&new)
    var assumed_b : &uint32 = [&uint32](&assumed)
    var res       :  uint32

    var mask = false
    repeat
      if not mask then
        assumed = old
        new     = op(assumed,operand)
        res     = cas_uint32([&uint32](address), @assumed_b, @new_b)
        old     = @[&typ](&res)
        mask    = assumed == old
      end
    until mask
  end
end

-- Operator quotes
local mul = macro(function(a, b) return `a*b end)
local add = macro(function(a, b) return `a+b end)
local div = macro(function(a, b) return `a/b end)
local max = macro(function(a, b) return
  quote
    var max
    if a > b then max = a
    else          max = b
    end
  in
    max
  end
end)
local min = macro(function(a, b) return
  quote 
    var min
    if a < b then min = a
    else          min = b
    end
  in
    min
  end
end)

--[[-----------------------------------------------------------------------]]--
--[[ Convenience Functions                                                 ]]--
--[[-----------------------------------------------------------------------]]--
local function throw_err() error('Cuda error') end
local function cuda_checkpoint()
  print('CUDA CHECK HERE')
  print(debug.traceback())
end
local cuda_error_checking = macro(function(code)
  --local function say_code()
  --    code:printpretty()
  --end
  return quote
    --say_code()
    --cuda_checkpoint()
    if code ~= 0 then
      C.printf("CUDA ERROR: %s\n", C.cudaGetErrorString(code))
      throw_err()
    end
  end
end)

local terra cuda_terra_malloc(size : uint64)
  var r : &opaque
  cuda_error_checking(C.cudaMalloc(&r, size))
  return r
end

local terra cuda_terra_free(ptr : &opaque)
  cuda_error_checking(C.cudaFree(ptr))
end

local terra cuda_memcpy_cpu_from_gpu(dst:&opaque, src:&opaque, N:uint64)
  cuda_error_checking(C.cudaMemcpy(dst, src, N, C.cudaMemcpyDeviceToHost))
end
local terra cuda_memcpy_gpu_from_cpu(dst:&opaque, src:&opaque, N:uint64)
  cuda_error_checking(C.cudaMemcpy(dst, src, N, C.cudaMemcpyHostToDevice))
end
local terra cuda_memcpy_gpu_from_gpu(dst:&opaque, src:&opaque, N:uint64)
  cuda_error_checking(C.cudaMemcpy(dst, src, N, C.cudaMemcpyDeviceToDevice))
end

local terra cuda_peek_at_last_error()
  cuda_error_checking(C.cudaPeekAtLastError())
end

local sync_temp_wrapper =
        terralib.externfunction("cudaThreadSynchronize", {} -> int)
local terra cuda_sync_wrapper_with_peek()
  var res = sync_temp_wrapper()
  cuda_peek_at_last_error()
end



--[[-----------------------------------------------------------------------]]--
--[[ Global Reductions                                                     ]]--
--[[-----------------------------------------------------------------------]]--

local ReductionObj = {}
ReductionObj.__index = ReductionObj

function ReductionObj.New(args)
  local ro = setmetatable({
    _ttype              = args.ttype or assert(false,'no ttype'),
    _blocksize          = args.blocksize or assert(false,'no blocksize'),
    _reduce_ident       = args.reduce_ident
                          or assert(false,'no reduce_ident'),
    _reduce_binop       = args.reduce_binop
                          or assert(false,'no reduce_binop'),
    _gpu_reduce_atomic  = args.gpu_reduce_atomic
                          or assert(false,'no gpu_reduce_atomic'),
  }, ReductionObj)

  -- initialization of shared memory variable
  ro._sharedmem     = cudalib.sharedmemory(ro._ttype, ro._blocksize)
  ro._sharedmemsize = terralib.sizeof(ro._ttype) * ro._blocksize

  return ro
end

--function ReductionObj:getSharedMemPtr()
--  return self._sharedmem
--end
function ReductionObj:sharedMemSize()
  return self._sharedmemsize
end
function ReductionObj:sharedMemInitCode(tid_sym)
  return quote
    [self._sharedmem][tid_sym] = [self._reduce_ident]
  end
end
-- returns a snippet of code to be included at the end of the kernel
function ReductionObj:sharedMemReductionCode(tid_sym, globalptr)
  -- Shared Memory Reduction Tree
  local step = self._blocksize
  local code = quote escape while step > 1 do
    step = step / 2
    emit quote if tid_sym < step then
      var exp = [self._reduce_binop(`[self._sharedmem][tid_sym],
                                    `[self._sharedmem][tid_sym + step])]
      terralib.attrstore(&[self._sharedmem][tid_sym], exp, {isvolatile=true})
    end end
  end end end

  -- Now append the reduction into the global counter
  code = quote
    [code]
    [self._gpu_reduce_atomic(`@[globalptr],
                             `[self._sharedmem][0])]
  end
  return code
end


--[[-----------------------------------------------------------------------]]--
--[[ gpu_util Interface                                                    ]]--
--[[-----------------------------------------------------------------------]]--
GPU.kernelwrap = require 'compiler.cukernelwrap'

GPU.printf     = printf
GPU.block_id   = block_id
GPU.thread_id  = thread_id
GPU.global_tid = global_tid
GPU.num_blocks = num_blocks

GPU.check                   = cuda_error_checking
GPU.malloc                  = cuda_terra_malloc
GPU.free                    = cuda_terra_free
GPU.memcpy_cpu_from_gpu     = cuda_memcpy_cpu_from_gpu
GPU.memcpy_gpu_from_cpu     = cuda_memcpy_gpu_from_cpu
GPU.memcpy_gpu_from_gpu     = cuda_memcpy_gpu_from_gpu
GPU.peek_last_error         = cuda_peek_at_last_error

GPU.barrier    = macro(function() return quote cudalib.nvvm_barrier0() end end)
GPU.sync       = cuda_sync_wrapper_with_peek
--GPU.sync       = terralib.externfunction("cudaThreadSynchronize", {} -> int)
GPU.device_sync = terralib.externfunction("cudaDeviceSynchronize", {} -> int)

GPU.get_grid_dimensions = get_grid_dimensions

GPU.cbrt  = cbrt
GPU.sqrt  = cudalib.nvvm_sqrt_rm_d
GPU.cos   = cos
GPU.acos  = acos
GPU.sin   = sin
GPU.asin  = asin
GPU.tan   = tan
GPU.atan  = atan
GPU.floor = cudalib.nvvm_floor_d
GPU.ceil  = cudalib.nvvm_ceil_d
GPU.fabs  = cudalib.nvvm_fabs_d
GPU.log   = log
GPU.pow   = pow
GPU.fmod  = fmod

-- Intrinsic atomic reductions:
GPU.atomic_add_float = atomic_add_float
GPU.atomic_max_int32 = reduce_max_int32
GPU.reduce_min_int32 = reduce_min_int32
GPU.reduce_add_int32 = reduce_add_int32
GPU.reduce_and_b32   = reduce_and_b32
GPU.reduce_or_b32    = reduce_or_b32

-- Slow operations:
GPU.atomic_add_uint64_SLOW = generate_slow_atomic_64(add,uint64)
GPU.atomic_add_double_SLOW = generate_slow_atomic_64(add,double)

GPU.atomic_mul_float_SLOW  = generate_slow_atomic_32(mul,float)
GPU.atomic_mul_double_SLOW = generate_slow_atomic_64(mul,double)
GPU.atomic_mul_int32_SLOW  = generate_slow_atomic_32(mul,int32)
GPU.atomic_mul_uint64_SLOW = generate_slow_atomic_64(mul,uint64)

GPU.atomic_div_float_SLOW  = generate_slow_atomic_32(div,float)
GPU.atomic_div_double_SLOW = generate_slow_atomic_64(div,double)

GPU.atomic_min_uint64_SLOW = generate_slow_atomic_64(min,uint64)
GPU.atomic_min_double_SLOW = generate_slow_atomic_64(min,double)
GPU.atomic_min_float_SLOW  = generate_slow_atomic_32(min,float)

GPU.atomic_max_uint64_SLOW = generate_slow_atomic_64(max,uint64)
GPU.atomic_max_double_SLOW = generate_slow_atomic_64(max,double)
GPU.atomic_max_float_SLOW  = generate_slow_atomic_32(max,float)

-- Algorithms
GPU.ReductionObj = ReductionObj


