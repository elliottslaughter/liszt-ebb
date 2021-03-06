--DISABLE-TEST

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
import 'ebb'
local L = require 'ebblib'
require "tests.test"

local Tetmesh = require 'INTERNAL_devapps.fem.tetmesh'
local VEGFileIO = require 'INTERNAL_devapps.fem.vegfileio'
local PN = require 'ebb.lib.pathname'
local U = require 'INTERNAL_devapps.fem.utils'


local mesh   = VEGFileIO.LoadTetmesh('INTERNAL_devapps/fem/turtle-volumetric-homogeneous.veg')

mesh.density = 1000
mesh.E = 250000
mesh.Nu = 0.45
mesh.lambdaLame = mesh.Nu * mesh.E / ( ( 1.0 + mesh.Nu ) * ( 1.0 - 2.0 * mesh.Nu ) )
mesh.muLame     = mesh.E / ( 2.0 * ( 1.0 + mesh.Nu) )

mesh.tetrahedra:NewField('Bm', L.mat3d):Load({ {0, 0, 0}, {0, 0, 0}, {0, 0, 0} })
mesh.tetrahedra:NewField('W',  L.double):Load(0)

mesh.vertices:NewField('q', L.vec3d):Load({0, 0, 0})
mesh.edges:NewField('stiffness', L.mat3d):Load({ {0, 0, 0}, {0, 0, 0}, {0, 0, 0} })
mesh.edges:NewField('stiffrp', L.mat3d):Load({ {0, 0, 0}, {0, 0, 0}, {0, 0, 0} })

mesh.tetrahedra:NewField('F',     L.mat3d):Load({ {0, 0, 0}, {0, 0, 0}, {0, 0, 0} })      
mesh.tetrahedra:NewField('FinvT', L.mat3d):Load({ {0, 0, 0}, {0, 0, 0}, {0, 0, 0} })      
mesh.tetrahedra:NewField('Fdet',  L.double):Load(0)

local ebb ComputeBAndW(t : mesh.tetrahedra)
  var Dm : L.mat3d
  var x4 : L.vec3d = t.v[3].pos
  for j = 0,3  do
    var le : L.vec3d = t.v[j].pos - x4
    for i = 0,3 do
      Dm[i,j] = le[i]
    end
  end
  var det = L.fabs(U.detMatrix3d(Dm))
  t.W  = det/6.0
  t.Bm = U.invertMatrix3d(Dm)
end

local ebb RecomputeAndResetTetTemporaries(t : mesh.tetrahedra)
 -- recompute
  var Ds : L.mat3d  = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
  var x4 = t.v[3].pos + t.v[3].q
  for j = 0, 3 do
    var le : L.vec3d = (t.v[j].pos + t.v[j].q) - x4
    for i = 0,3 do
      Ds[i,j] = le[i]
    end
  end
  var Bm : L.mat3d = t.Bm
  var F  : L.mat3d  = U.multiplyMatrices3d(Ds, Bm)
  t.F = F
  var Finv = U.invertMatrix3d(F)
  t.FinvT  = U.transposeMatrix3(Finv)
  t.Fdet   = L.fabs(U.detMatrix3d(F))
end

local ebb dPdF(t, dF)
  var dFT      = U.transposeMatrix3(dF)
  var FinvT    = t.FinvT
  var c1       = t.muLame - t.lambdaLame * L.log(t.Fdet)
  var dFTFinvT = U.multiplyMatrices3d(dFT, FinvT)
  var c2       = t.lambdaLame * (dFTFinvT[0,0] + dFTFinvT[1,1] + dFTFinvT[2,2])
  var FinvTdFTFinvT = U.multiplyMatrices3d(FinvT, dFTFinvT)
  var dP = (t.muLame * dF) + (c1 * FinvTdFTFinvT) + c2 * FinvT
  return dP
end

local ebb ComputeStiffnessMatrix(t : mesh.tetrahedra)
  var Bm  : L.mat3d = t.Bm
  var BmT : L.mat3d = U.transposeMatrix3(t.Bm)
  var dFRow : L.mat4x3d = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
  -- assemble dFRow
  for i = 0,3 do
    for j = 0,3 do
      dFRow[i,j]  =  Bm[i,j]
      dFRow[3,j] += -Bm[i,j]
    end
  end
  -- for every vertex, assemble interactions with every other vertex
  for v = 0,4 do
    for k = 0,3 do
      var dF : L.mat3d = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
      for j = 0,3 do
        dF[k,j] = dFRow[v,j]
      end
      var dP : L.mat3d = dPdF(t, dF)
      var dH : L.mat3d = (t.W) * U.multiplyMatrices3d(dP, BmT)
      for i = 0,3 do
        for r = 0,3 do
          t.e[i,v].stiffness[r, k] +=  dH[r, i]
          t.e[3,v].stiffness[r, k] += -dH[r, i]
        end
      end
    end
  end
end

local ebb ReduceStiffnessPrecision(e : mesh.edges)
  for i = 0,3 do
    for j = 0,3 do
      e.stiffrp[i,j] = L.floor(e.stiffness[i,j]/1000)
    end
  end
end

mesh.tetrahedra:foreach(ComputeBAndW)
mesh.tetrahedra:foreach(RecomputeAndResetTetTemporaries)
mesh.tetrahedra:foreach(ComputeStiffnessMatrix)
mesh.edges:foreach(ReduceStiffnessPrecision)

mesh.edges.stiffrp:Print()
