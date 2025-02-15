local bench = script and require(script.Parent.bench_support) or require("bench_support")

-- Copyright 2008 the V8 project authors. All rights reserved.
-- Copyright 1996 John Maloney and Mario Wolczko.

-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 2 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA


-- This implementation of the DeltaBlue benchmark is derived
-- from the Smalltalk implementation by John Maloney and Mario
-- Wolczko. Some parts have been translated directly, whereas
-- others have been modified more aggressively to make it feel
-- more like a JavaScript program.


--
-- A JavaScript implementation of the DeltaBlue constraint-solving
-- algorithm, as described in:
--
-- "The DeltaBlue Algorithm: An Incremental Constraint Hierarchy Solver"
--   Bjorn N. Freeman-Benson and John Maloney
--   January 1990 Communications of the ACM,
--   also available as University of Washington TR 89-08-06.
--
-- Beware: this benchmark is written in a grotesque style where
-- the constraint model is built by side-effects from constructors.
-- I've kept it this way to avoid deviating too much from the original
-- implementation.
--

function class(base)
	local T = {}
	T.__index = T

	if base then
		T.super = base
		setmetatable(T, base)
	end

	function T.new(...)
		local O = {}
		setmetatable(O, T)
		O:constructor(...)
		return O
	end

	return T
end

local planner

--- O b j e c t   M o d e l ---

local function alert (...) print(...) end

local OrderedCollection = class()

function OrderedCollection:constructor()
	 self.elms = {}
end

function OrderedCollection:add(elm)
	 self.elms[#self.elms + 1] = elm
end

function OrderedCollection:at (index)
	 return self.elms[index]
end

function OrderedCollection:size ()
	 return #self.elms
end

function OrderedCollection:removeFirst ()
	 local e = self.elms[#self.elms]
	 self.elms[#self.elms] = nil
	 return e
end

function OrderedCollection:remove (elm)
	 local index = 0
	 local skipped = 0

	 for i = 1, #self.elms do
			local value = self.elms[i]
			if value ~= elm then
				 self.elms[index] = value
				 index = index + 1
			else
				 skipped = skipped + 1
			end
	 end

	 local l = #self.elms
	 for i = 1, skipped do self.elms[l - i + 1] = nil end
end

--
-- S t r e n g t h
--

--
-- Strengths are used to measure the relative importance of constraints.
-- New strengths may be inserted in the strength hierarchy without
-- disrupting current constraints.  Strengths cannot be created outside
-- this class, so pointer comparison can be used for value comparison.
--

local Strength = class()

function Strength:constructor(strengthValue, name)
	 self.strengthValue = strengthValue
	 self.name = name
end

function Strength.stronger (s1, s2)
	 return s1.strengthValue < s2.strengthValue
end

function Strength.weaker (s1, s2)
	 return s1.strengthValue > s2.strengthValue
end

function Strength.weakestOf (s1, s2)
	 return Strength.weaker(s1, s2) and s1 or s2
end

function Strength.strongest (s1, s2)
	 return Strength.stronger(s1, s2) and s1 or s2
end

function Strength:nextWeaker ()
	 local v = self.strengthValue
	 if v == 0 then return Strength.WEAKEST
	 elseif v == 1 then return Strength.WEAK_DEFAULT
	 elseif v == 2 then return Strength.NORMAL
	 elseif v == 3 then return Strength.STRONG_DEFAULT
	 elseif v == 4 then return Strength.PREFERRED
	 elseif v == 5 then return Strength.REQUIRED
	 end
end

-- Strength constants.
Strength.REQUIRED        = Strength.new(0, "required");
Strength.STONG_PREFERRED = Strength.new(1, "strongPreferred");
Strength.PREFERRED       = Strength.new(2, "preferred");
Strength.STRONG_DEFAULT  = Strength.new(3, "strongDefault");
Strength.NORMAL          = Strength.new(4, "normal");
Strength.WEAK_DEFAULT    = Strength.new(5, "weakDefault");
Strength.WEAKEST         = Strength.new(6, "weakest");

--
-- C o n s t r a i n t
--

--
-- An abstract class representing a system-maintainable relationship
-- (or "constraint") between a set of variables. A constraint supplies
-- a strength instance variable; concrete subclasses provide a means
-- of storing the constrained variables and other information required
-- to represent a constraint.
--

local Constraint = class ()

function Constraint:constructor(strength)
	 self.strength = strength
end

--
-- Activate this constraint and attempt to satisfy it.
--
function Constraint:addConstraint ()
	 self:addToGraph()
	 planner:incrementalAdd(self)
end

--
-- Attempt to find a way to enforce this constraint. If successful,
-- record the solution, perhaps modifying the current dataflow
-- graph. Answer the constraint that this constraint overrides, if
-- there is one, or nil, if there isn't.
-- Assume: I am not already satisfied.
--
function Constraint:satisfy (mark)
	 self:chooseMethod(mark)
	 if not self:isSatisfied() then
			if self.strength == Strength.REQUIRED then
				 alert("Could not satisfy a required constraint!")
			end
			return nil
	 end
	 self:markInputs(mark)
	 local out = self:output()
	 local overridden = out.determinedBy
	 if overridden ~= nil then overridden:markUnsatisfied() end
	 out.determinedBy = self
	 if not planner:addPropagate(self, mark) then alert("Cycle encountered") end
	 out.mark = mark
	 return overridden
end

function Constraint:destroyConstraint ()
	 if self:isSatisfied()
	 then planner:incrementalRemove(self)
	 else self:removeFromGraph()
	 end
end

--
-- Normal constraints are not input constraints.  An input constraint
-- is one that depends on external state, such as the mouse, the
-- keyboard, a clock, or some arbitrary piece of imperative code.
--
function Constraint:isInput ()
	 return false
end


--
-- U n a r y   C o n s t r a i n t
--

--
-- Abstract superclass for constraints having a single possible output
-- variable.
--

local UnaryConstraint = class(Constraint)

function UnaryConstraint:constructor (v, strength)
	 UnaryConstraint.super.constructor(self, strength)
	 self.myOutput = v
	 self.satisfied = false
	 self:addConstraint()
end

--
-- Adds this constraint to the constraint graph
--
function UnaryConstraint:addToGraph ()
	 self.myOutput:addConstraint(self)
	 self.satisfied = false
end

--
-- Decides if this constraint can be satisfied and records that
-- decision.
--
function UnaryConstraint:chooseMethod (mark)
	 self.satisfied = (self.myOutput.mark ~= mark)
	 and Strength.stronger(self.strength, self.myOutput.walkStrength);
end

--
-- Returns true if this constraint is satisfied in the current solution.
--
function UnaryConstraint:isSatisfied ()
	 return self.satisfied;
end

function UnaryConstraint:markInputs (mark)
	 -- has no inputs
end

--
-- Returns the current output variable.
--
function UnaryConstraint:output ()
	 return self.myOutput
end

--
-- Calculate the walkabout strength, the stay flag, and, if it is
-- 'stay', the value for the current output of this constraint. Assume
-- this constraint is satisfied.
--
function UnaryConstraint:recalculate ()
	 self.myOutput.walkStrength = self.strength
	 self.myOutput.stay = not self:isInput()
	 if self.myOutput.stay then
			self:execute() -- Stay optimization
	 end
end

--
-- Records that this constraint is unsatisfied
--
function UnaryConstraint:markUnsatisfied ()
	 self.satisfied = false
end

function UnaryConstraint:inputsKnown ()
	 return true
end

function UnaryConstraint:removeFromGraph ()
	 if self.myOutput ~= nil then
			self.myOutput:removeConstraint(self)
	 end
	 self.satisfied = false
end

--
-- S t a y   C o n s t r a i n t
--

--
-- Variables that should, with some level of preference, stay the same.
-- Planners may exploit the fact that instances, if satisfied, will not
-- change their output during plan execution.  This is called "stay
-- optimization".
--

local StayConstraint = class(UnaryConstraint)

function StayConstraint:constructor(v, str)
	 StayConstraint.super.constructor(self, v, str) 
end

function StayConstraint:execute ()
	 -- Stay constraints do nothing
end

--
-- E d i t   C o n s t r a i n t
--

--
-- A unary input constraint used to mark a variable that the client
-- wishes to change.
--

local EditConstraint = class (UnaryConstraint)

function EditConstraint:constructor(v, str)
	 EditConstraint.super.constructor(self, v, str)
end

--
-- Edits indicate that a variable is to be changed by imperative code.
--
function EditConstraint:isInput ()
	 return true
end

function EditConstraint:execute ()
	 -- Edit constraints do nothing
end

--
-- B i n a r y   C o n s t r a i n t
--

local Direction = {}
Direction.NONE     = 0
Direction.FORWARD  = 1
Direction.BACKWARD = -1

--
-- Abstract superclass for constraints having two possible output
-- variables.
--

local BinaryConstraint = class(Constraint)

function BinaryConstraint:constructor(var1, var2, strength)
	 BinaryConstraint.super.constructor(self, strength);
	 self.v1 = var1
	 self.v2 = var2
	 self.direction = Direction.NONE
	 self:addConstraint()
end


--
-- Decides if this constraint can be satisfied and which way it
-- should flow based on the relative strength of the variables related,
-- and record that decision.
--
function BinaryConstraint:chooseMethod (mark)
	 if self.v1.mark == mark then
			self.direction = (self.v2.mark ~= mark and Strength.stronger(self.strength, self.v2.walkStrength)) and Direction.FORWARD or Direction.NONE
	 end
	 if self.v2.mark == mark then
			self.direction = (self.v1.mark ~= mark and Strength.stronger(self.strength, self.v1.walkStrength)) and Direction.BACKWARD or Direction.NONE
	 end
	 if Strength.weaker(self.v1.walkStrength, self.v2.walkStrength) then
			self.direction = Strength.stronger(self.strength, self.v1.walkStrength) and Direction.BACKWARD or Direction.NONE
	 else
			self.direction = Strength.stronger(self.strength, self.v2.walkStrength) and Direction.FORWARD or Direction.BACKWARD
	 end
end

--
-- Add this constraint to the constraint graph
--
function BinaryConstraint:addToGraph ()
	 self.v1:addConstraint(self)
	 self.v2:addConstraint(self)
	 self.direction = Direction.NONE
end

--
-- Answer true if this constraint is satisfied in the current solution.
--
function BinaryConstraint:isSatisfied ()
	 return self.direction ~= Direction.NONE
end

--
-- Mark the input variable with the given mark.
--
function BinaryConstraint:markInputs (mark)
	 self:input().mark = mark
end

--
-- Returns the current input variable
--
function BinaryConstraint:input ()
	 return (self.direction == Direction.FORWARD) and self.v1 or self.v2
end

--
-- Returns the current output variable
--
function BinaryConstraint:output ()
	 return (self.direction == Direction.FORWARD) and self.v2 or self.v1
end

--
-- Calculate the walkabout strength, the stay flag, and, if it is
-- 'stay', the value for the current output of this
-- constraint. Assume this constraint is satisfied.
--
function BinaryConstraint:recalculate ()
	 local ihn = self:input()
	 local out = self:output()
	 out.walkStrength = Strength.weakestOf(self.strength, ihn.walkStrength);
	 out.stay = ihn.stay
	 if out.stay then self:execute() end
end

--
-- Record the fact that self constraint is unsatisfied.
--
function BinaryConstraint:markUnsatisfied ()
	 self.direction = Direction.NONE
end

function BinaryConstraint:inputsKnown (mark)
	 local i = self:input()
	 return i.mark == mark or i.stay or i.determinedBy == nil
end

function BinaryConstraint:removeFromGraph ()
	 if (self.v1 ~= nil) then self.v1:removeConstraint(self) end
	 if (self.v2 ~= nil) then self.v2:removeConstraint(self) end
	 self.direction = Direction.NONE
end

--
-- S c a l e   C o n s t r a i n t
-- 

--
-- Relates two variables by the linear scaling relationship: "v2 =
-- (v1 * scale) + offset". Either v1 or v2 may be changed to maintain
-- this relationship but the scale factor and offset are considered
-- read-only.
--

local ScaleConstraint = class (BinaryConstraint)

function ScaleConstraint:constructor(src, scale, offset, dest, strength)
	 self.direction = Direction.NONE
	 self.scale = scale
	 self.offset = offset
	 ScaleConstraint.super.constructor(self, src, dest, strength)
end


--
-- Adds this constraint to the constraint graph.
--
function ScaleConstraint:addToGraph ()
	 ScaleConstraint.super.addToGraph(self)
	 self.scale:addConstraint(self)
	 self.offset:addConstraint(self)
end

function ScaleConstraint:removeFromGraph ()
	 ScaleConstraint.super.removeFromGraph(self)
	 if (self.scale ~= nil) then self.scale:removeConstraint(self) end
	 if (self.offset ~= nil) then self.offset:removeConstraint(self) end
end

function ScaleConstraint:markInputs (mark)
	 ScaleConstraint.super.markInputs(self, mark);
	 self.offset.mark = mark
	 self.scale.mark = mark
end

--
-- Enforce this constraint. Assume that it is satisfied.
--
function ScaleConstraint:execute ()
	 if self.direction == Direction.FORWARD then
			self.v2.value = self.v1.value * self.scale.value + self.offset.value
	 else
			self.v1.value = (self.v2.value - self.offset.value) / self.scale.value
	 end
end

--
-- Calculate the walkabout strength, the stay flag, and, if it is
-- 'stay', the value for the current output of this constraint. Assume
-- this constraint is satisfied.
--
function ScaleConstraint:recalculate ()
	 local ihn = self:input()
	 local out = self:output()
	 out.walkStrength = Strength.weakestOf(self.strength, ihn.walkStrength)
	 out.stay = ihn.stay and self.scale.stay and self.offset.stay
	 if out.stay then self:execute() end
end

--
-- E q u a l i t  y   C o n s t r a i n t
--

--
-- Constrains two variables to have the same value.
--

local EqualityConstraint = class (BinaryConstraint)

function EqualityConstraint:constructor(var1, var2, strength)
	 EqualityConstraint.super.constructor(self, var1, var2, strength)
end


--
-- Enforce this constraint. Assume that it is satisfied.
--
function EqualityConstraint:execute ()
	 self:output().value = self:input().value
end

--
-- V a r i a b l e
--

--
-- A constrained variable. In addition to its value, it maintain the
-- structure of the constraint graph, the current dataflow graph, and
-- various parameters of interest to the DeltaBlue incremental
-- constraint solver.
--
local Variable = class ()

function Variable:constructor(name, initialValue)
	 self.value = initialValue or 0
	 self.constraints = OrderedCollection.new()
	 self.determinedBy = nil
	 self.mark = 0
	 self.walkStrength = Strength.WEAKEST
	 self.stay = true
	 self.name = name
end

--
-- Add the given constraint to the set of all constraints that refer
-- this variable.
--
function Variable:addConstraint (c)
	 self.constraints:add(c)
end

--
-- Removes all traces of c from this variable.
--
function Variable:removeConstraint (c)
	 self.constraints:remove(c)
	 if self.determinedBy == c then
			self.determinedBy = nil
	 end
end

--
-- P l a n n e r
--

--
-- The DeltaBlue planner
--
local Planner = class()
function Planner:constructor()
	 self.currentMark = 0
end

--
-- Attempt to satisfy the given constraint and, if successful,
-- incrementally update the dataflow graph.  Details: If satisfying
-- the constraint is successful, it may override a weaker constraint
-- on its output. The algorithm attempts to resatisfy that
-- constraint using some other method. This process is repeated
-- until either a) it reaches a variable that was not previously
-- determined by any constraint or b) it reaches a constraint that
-- is too weak to be satisfied using any of its methods. The
-- variables of constraints that have been processed are marked with
-- a unique mark value so that we know where we've been. This allows
-- the algorithm to avoid getting into an infinite loop even if the
-- constraint graph has an inadvertent cycle.
--
function Planner:incrementalAdd (c)
	 local mark = self:newMark()
	 local overridden = c:satisfy(mark)
	 while overridden ~= nil do
			overridden = overridden:satisfy(mark)
	 end
end

--
-- Entry point for retracting a constraint. Remove the given
-- constraint and incrementally update the dataflow graph.
-- Details: Retracting the given constraint may allow some currently
-- unsatisfiable downstream constraint to be satisfied. We therefore collect
-- a list of unsatisfied downstream constraints and attempt to
-- satisfy each one in turn. This list is traversed by constraint
-- strength, strongest first, as a heuristic for avoiding
-- unnecessarily adding and then overriding weak constraints.
-- Assume: c is satisfied.
--
function Planner:incrementalRemove (c)
	 local out = c:output()
	 c:markUnsatisfied()
	 c:removeFromGraph()
	 local unsatisfied = self:removePropagateFrom(out)
	 local strength = Strength.REQUIRED
	 repeat
			for i = 1, unsatisfied:size() do
				 local u = unsatisfied:at(i)
				 if u.strength == strength then
						self:incrementalAdd(u)
				 end
			end
			strength = strength:nextWeaker()
	 until strength == Strength.WEAKEST
end

--
-- Select a previously unused mark value.
--
function Planner:newMark ()
	 self.currentMark = self.currentMark + 1
	 return self.currentMark
end

--
-- Extract a plan for resatisfaction starting from the given source
-- constraints, usually a set of input constraints. This method
-- assumes that stay optimization is desired; the plan will contain
-- only constraints whose output variables are not stay. Constraints
-- that do no computation, such as stay and edit constraints, are
-- not included in the plan.
-- Details: The outputs of a constraint are marked when it is added
-- to the plan under construction. A constraint may be appended to
-- the plan when all its input variables are known. A variable is
-- known if either a) the variable is marked (indicating that has
-- been computed by a constraint appearing earlier in the plan), b)
-- the variable is 'stay' (i.e. it is a constant at plan execution
-- time), or c) the variable is not determined by any
-- constraint. The last provision is for past states of history
-- variables, which are not stay but which are also not computed by
-- any constraint.
-- Assume: sources are all satisfied.
--
local Plan -- FORWARD DECLARATION
function Planner:makePlan (sources)
	 local mark = self:newMark()
	 local plan = Plan.new()
	 local todo = sources
	 while todo:size() > 0 do
			local c = todo:removeFirst()
			if c:output().mark ~= mark and c:inputsKnown(mark) then
				 plan:addConstraint(c)
				 c:output().mark = mark
				 self:addConstraintsConsumingTo(c:output(), todo)
			end
	 end
	 return plan
end

--
-- Extract a plan for resatisfying starting from the output of the
-- given constraints, usually a set of input constraints.
--
function Planner:extractPlanFromConstraints (constraints)
	 local sources = OrderedCollection.new()
	 for i = 1, constraints:size() do
			local c = constraints:at(i)
			if c:isInput() and c:isSatisfied() then
				 -- not in plan already and eligible for inclusion
				 sources:add(c)
			end
	 end
	 return self:makePlan(sources)
end

--
-- Recompute the walkabout strengths and stay flags of all variables
-- downstream of the given constraint and recompute the actual
-- values of all variables whose stay flag is true. If a cycle is
-- detected, remove the given constraint and answer
-- false. Otherwise, answer true.
-- Details: Cycles are detected when a marked variable is
-- encountered downstream of the given constraint. The sender is
-- assumed to have marked the inputs of the given constraint with
-- the given mark. Thus, encountering a marked node downstream of
-- the output constraint means that there is a path from the
-- constraint's output to one of its inputs.
--
function Planner:addPropagate (c, mark)
	 local todo = OrderedCollection.new()
	 todo:add(c)
	 while todo:size() > 0 do
			local d = todo:removeFirst()
			if d:output().mark == mark then
				 self:incrementalRemove(c)
				 return false
			end
			d:recalculate()
			self:addConstraintsConsumingTo(d:output(), todo)
	 end
	 return true
end


--
-- Update the walkabout strengths and stay flags of all variables
-- downstream of the given constraint. Answer a collection of
-- unsatisfied constraints sorted in order of decreasing strength.
--
function Planner:removePropagateFrom (out)
	 out.determinedBy = nil
	 out.walkStrength = Strength.WEAKEST
	 out.stay = true
	 local unsatisfied = OrderedCollection.new()
	 local todo = OrderedCollection.new()
	 todo:add(out)
	 while todo:size() > 0 do
			local v = todo:removeFirst()
			for i = 1, v.constraints:size() do
				 local c = v.constraints:at(i)
				 if not c:isSatisfied() then unsatisfied:add(c) end
			end
			local determining = v.determinedBy
			for i = 1, v.constraints:size() do
				 local next = v.constraints:at(i);
				 if next ~= determining and next:isSatisfied() then
						next:recalculate()
						todo:add(next:output())
				 end
			end
	 end
	 return unsatisfied
end

function Planner:addConstraintsConsumingTo (v, coll)
	 local determining = v.determinedBy
	 local cc = v.constraints
	 for i = 1, cc:size() do
			local c = cc:at(i)
			if c ~= determining and c:isSatisfied() then
				 coll:add(c)
			end
	 end
end

--
-- P l a n
--

--
-- A Plan is an ordered list of constraints to be executed in sequence
-- to resatisfy all currently satisfiable constraints in the face of
-- one or more changing inputs.
--
Plan = class()
function Plan:constructor()
	 self.v = OrderedCollection.new()
end

function Plan:addConstraint (c)
	 self.v:add(c)
end

function Plan:size ()
	 return self.v:size()
end

function Plan:constraintAt (index)
	 return self.v:at(index)
end

function Plan:execute ()
	 for i = 1, self:size() do
			local c = self:constraintAt(i)
			c:execute()
	 end
end

--
-- M a i n
--

--
-- This is the standard DeltaBlue benchmark. A long chain of equality
-- constraints is constructed with a stay constraint on one end. An
-- edit constraint is then added to the opposite end and the time is
-- measured for adding and removing this constraint, and extracting
-- and executing a constraint satisfaction plan. There are two cases.
-- In case 1, the added constraint is stronger than the stay
-- constraint and values must propagate down the entire length of the
-- chain. In case 2, the added constraint is weaker than the stay
-- constraint so it cannot be accommodated. The cost in this case is,
-- of course, very low. Typical situations lie somewhere between these
-- two extremes.
--
local function chainTest(n)
	 planner = Planner.new()
	 local prev = nil
	 local first = nil
	 local last = nil

	 -- Build chain of n equality constraints
	 for i = 0, n do
			local name = "v" .. i;
			local v = Variable.new(name)
			if prev ~= nil then EqualityConstraint.new(prev, v, Strength.REQUIRED) end
			if i == 0 then first = v end
			if i == n then last = v end
			prev = v
	 end

	 StayConstraint.new(last, Strength.STRONG_DEFAULT)
	 local edit = EditConstraint.new(first, Strength.PREFERRED)
	 local edits = OrderedCollection.new()
	 edits:add(edit)
	 local plan = planner:extractPlanFromConstraints(edits)
	 for i = 0, 99 do
			first.value = i
			plan:execute()
			if last.value ~= i then
				 alert("Chain test failed.")
			end
	 end
end

local function change(v, newValue)
	 local edit = EditConstraint.new(v, Strength.PREFERRED)
	 local edits = OrderedCollection.new()
	 edits:add(edit)
	 local plan = planner:extractPlanFromConstraints(edits)
	 for i = 1, 10 do
			v.value = newValue
			plan:execute()
	 end
	 edit:destroyConstraint()
end

--
-- This test constructs a two sets of variables related to each
-- other by a simple linear transformation (scale and offset). The
-- time is measured to change a variable on either side of the
-- mapping and to change the scale and offset factors.
--
local function projectionTest(n)
	 planner = Planner.new();
	 local scale = Variable.new("scale", 10);
	 local offset = Variable.new("offset", 1000);
	 local src = nil
	 local dst = nil;

	 local dests = OrderedCollection.new();
	 for i = 0, n - 1 do
			src = Variable.new("src" .. i, i);
			dst = Variable.new("dst" .. i, i);
			dests:add(dst);
			StayConstraint.new(src, Strength.NORMAL);
			ScaleConstraint.new(src, scale, offset, dst, Strength.REQUIRED);
	 end

	 change(src, 17)
	 if dst.value ~= 1170 then alert("Projection 1 failed") end
	 change(dst, 1050)
	 if src.value ~= 5 then alert("Projection 2 failed") end
	 change(scale, 5)
	 for i = 0, n - 2 do
			if dests:at(i + 1).value ~= i * 5 + 1000 then
				 alert("Projection 3 failed")
			end
	 end
	 change(offset, 2000)
	 for i = 0, n - 2 do
			if dests:at(i + 1).value ~= i * 5 + 2000 then
				 alert("Projection 4 failed")
			end
	 end
end

function test()
	local t0 = os.clock()
	chainTest(1000);
	projectionTest(1000);
	local t1 = os.clock()
	return t1-t0
end	

bench.runCode(test, "deltablue")
