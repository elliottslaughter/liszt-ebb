-- The MIT License (MIT)
-- 
-- Copyright (c) 2015 Stanford University.
-- All rights reserved.
-- 
-- Permission is hereby granted, free of charge, to any person obtaining a
-- copy of this software and associated documentation files (the "Software"),
-- to deal in the Software without restriction, including without limitation
-- the rights to use, copy, modify, merge, publish, distribute, sublicense,
-- and/or sell copies of the Software, and to permit persons to whom the
-- Software is furnished to do so, subject to the following conditions:
-- 
-- The above copyright notice and this permission notice shall be included
-- in all copies or substantial portions of the Software.
-- 
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING 
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
-- DEALINGS IN THE SOFTWARE.

local CSV = {}
package.loaded["ebb.io.csv"] = CSV

local C     = require "ebb.src.c"       -- TODO: Don't expose compiler
local DLD   = require "ebb.lib.dld"
local L     = require "ebblib"
local PN    = require "ebb.lib.pathname"

-------------------------------------------------------------------------------

local loader_cache = {}
local function get_cached_loader(typ)
  if loader_cache[typ] then return loader_cache[typ] end

  local btyp    = typ:terrabasetype()
  local typfmt  = ""
  if      btyp == int then      typfmt = "%d"
  elseif  btyp == uint64 then   typfmt = "%u"
  --elseif  btyp == bool then     typfmt = "%d" -- try to not have for now
  elseif  btyp == float then    typfmt = "%f"
  elseif  btyp == double then   typfmt = "%lf"
  else    assert(false, "unrecognized base type in CSV.Load") end

  -- some Terra macro programming
  local fp = symbol('fp')
  -- error check
  local ec = macro(function(test, msg, ...)
    local varargs = {...}
    if msg then msg = quote C.fprintf(C.stderr, msg, varargs) end
           else msg = {} end
    return quote
      if not test then
        C.fclose(fp)
        [msg]
        return 1
      end
    end
  end)

  local terra CSVLoad(dld : &DLD.C_DLD, filename : rawstring) : int
    var [fp] = C.fopen(filename, 'r')
    ec( fp ~= nil, "Cannot open CSV file for reading\n" )

    var s    = dld.dim_stride
    var dim  = dld.dim_size
    var st   = dld.type_stride
    var dimt = dld.type_dims
    var nt   = dimt[0] * dimt[1]

    var bt  : btyp     -- base type
    var c   : int8     -- delimiter in csv, comma

    var ptr = [&btyp](dld.address)

    for i = 0, dim[0] do
      for j = 0, dim[1] do
        for k = 0, dim[2] do
          var linidx = i*s[0] + j*s[1] + k*s[2]

          for it = 0, dimt[0] do
            for jt = 0, dimt[1] do
              var offset = it*dimt[1] + jt

              ec( C.fscanf(fp, typfmt, &bt) == 1, "Expected entry\n" )
              ec( C.ferror(fp) == 0 and
                  C.feof(fp)   == 0, "Reached Error or EOF while scanning\n" )
              ptr[ nt*linidx + offset ] = bt
              if offset ~= nt-1 then
                c = 0
                while (c ~= 44) do
                  c = C.fgetc(fp)
                  ec( (c == 32 or c == 44) and
                      C.ferror(fp) == 0 and
                      C.feof(fp)   == 0,
                      "Expected a comma or a space in CSV file\n" )
                end
              end

            end
          end

        end
      end
    end
    c = 0
    repeat
      ec( c == 0 or c == 32 or (c >= 9 and c <= 13),
          ["CSV file longer than expected. "..
           "Expected space or end of file.\n"..
           "Got ASCII code %d\n"], c )
      c = C.fgetc(fp)
    until C.feof(fp) ~= 0

    C.fclose(fp)
    return 0 -- success
  end
  CSVLoad:setname('CSVLoad_'..tostring(typ))

  loader_cache[typ] = CSVLoad
  return CSVLoad
end

CSV.Load = L.NewLoader(function(field, filename)
  if PN.is_pathname(filename) then filename = tostring(filename) end
  if type(filename) ~= 'string' then
    error('CSV.Load expected a filename argument', 3)
  end

  local tfunc   = get_cached_loader(field:Type())
  local errcode = field:Load(tfunc, filename)

  if errcode ~= 0 then
    error('Error while loading CSV file '..filename, 3)
  end
end)

-------------------------------------------------------------------------------


local dumper_cache = {}
local function get_cached_dumper(typ, precision)
  if dumper_cache[typ] then
    if dumper_cache[typ][precision] then
      return dumper_cache[typ][precision]
    end
  else
    dumper_cache[typ] = {}
  end

  local precision_str = ""
  if precision ~= 0 then precision_str = "."..tostring(precision) end

  local btyp    = typ:terrabasetype()
  local typfmt  = ""
  if      btyp == int then      typfmt = "%d"
  elseif  btyp == uint64 then   typfmt = "%u"
  --elseif  btyp == bool then     typfmt = "%d" -- try to not have for now
  elseif  btyp == float then    typfmt = "%"..precision_str.."f"
  elseif  btyp == double then   typfmt = "%"..precision_str.."lf"
  else    assert(false, "unrecognized base type in CSV.Dump") end

  -- some Terra macro programming
  local fp = symbol('fp')
  -- error check
  local ec = macro(function(test, msg, ...)
    local varargs = {...}
    if msg then msg = quote C.fprintf(C.stderr, msg, varargs) end
           else msg = {} end
    return quote
      if not test then
        C.fclose(fp)
        [msg]
        return 1
      end
    end
  end)

  local terra CSVDump(dld : &DLD.C_DLD, filename : rawstring) : int
    var [fp] = C.fopen(filename, 'w')
    ec( fp ~= nil, "Cannot open CSV file for writing\n" )

    var s    = dld.dim_stride
    var dim  = dld.dim_size
    var st   = dld.type_stride
    var dimt = dld.type_dims
    var nt   = dimt[0] * dimt[1]

    var bt  : btyp     -- base type
    var c   : int8     -- delimiter in csv, comma

    var ptr = [&btyp](dld.address)

    for i = 0, dim[0] do
      for j = 0, dim[1] do
        for k = 0, dim[2] do
          var linidx = i*s[0] + j*s[1] + k*s[2]

          for it = 0, dimt[0] do
            for jt = 0, dimt[1] do
              var offset = it*dimt[1] + jt

              bt = ptr[ nt*linidx + offset ]
              ec( C.fprintf(fp, typfmt, bt) > 0, "Error writing entry\n" )
              if offset ~= nt-1 then
                ec( C.fprintf(fp, ", ") > 0, "Error writing comma\n" )
              end

            end
          end

          ec( C.fprintf(fp, "\n") > 0, "Error writing Newline\n" )
        end
      end
    end

    C.fclose(fp)
    return 0 -- success
  end
  CSVDump:setname('CSVDump_'..tostring(typ))

  dumper_cache[typ][precision] = CSVDump
  return CSVDump
end


CSV.Dump = L.NewDumper(function(field, filename, args)
  if PN.is_pathname(filename) then filename = tostring(filename) end
  if type(filename) ~= 'string' then
    error('CSV.Dump expected a filename argument', 3)
  end

  args = args or {}
  local precision = args.precision or 0 -- 0 == nil

  local tfunc   = get_cached_dumper(field:Type(), precision)
  local errcode = field:Dump(tfunc, filename)

  if errcode ~= 0 then
    error('Error while dumping CSV file '..filename, 3)
  end
end)

