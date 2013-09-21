package.path = package.path .. ";./tests/?.lua;?.lua"
require "test"
import "compiler/liszt"


------------------
-- Should pass: --
------------------
local a  = Vector.new(float, {1,     2, 3.29})
local z  = Vector.new(float, {4, 5.392,    6})

local a4 = Vector.new(float, {3.4, 4.3, 5, 6.153})
local ai = Vector.new(int,   {2, 3, 4})
local ab = Vector.new(bool,  {true, false, true})

local b  = 3 * a
local b2 = a * 3
local c  = a + b
local d  = a + ai
local e  = ai / 4.5
local f  = c - Vector.new(float, {8, 8, 8})
local g  = a % 3
local h  = a4 % -2

test.eq(b.size,  a.size)
test.eq(b2.size, a.size)
test.eq(c.size,  a.size)
test.eq(d.size,  a.size)
test.eq(d.data_type, a.data_type)
test.eq(b.data_type, b2.data_type)
test.eq(e.data_type, float)

test.aeq(a.data, {1, 2, 3.29})
test.aeq(b.data, {3*1, 3*2, 3*3.29})
test.aeq(b.data, b2.data)


--------------------
-- Expected fails --
--------------------
function div_fail ()
	return 4.5 / ai
end

function add_fail ()
	return 2 + a
end

function add_fail2 ()
	return a + 2
end

function sub_fail ()
	return 2 - a
end

function sub_fail2 ()
	return a - 2
end

function mult_fail ()
	return a * b
end

function power_fail ()
	return a ^ 3
end

function type_fail ()
	return ai / true
end

function type_fail2 ()
	return a + a4
end

function type_fail3 ()
	return a4 + a
end

function type_fail4 ()
	return a - a4
end

function type_fail5 ()
	return a4 - a
end

test.fail_function(div_fail,   "divide")
test.fail_function(add_fail,   "add")
test.fail_function(add_fail2,  "add")
test.fail_function(sub_fail,   "subtract")
test.fail_function(sub_fail2,  "subtract")
test.fail_function(mult_fail,  "multiply")
test.fail_function(power_fail, "arithmetic") -- Lua error here, for now

test.fail_function(type_fail,  "numeric")
test.fail_function(type_fail2, "lengths")
test.fail_function(type_fail3, "lengths")
test.fail_function(type_fail4, "lengths")
test.fail_function(type_fail5, "lengths")