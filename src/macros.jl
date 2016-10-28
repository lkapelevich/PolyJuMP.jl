using JuMP
import JuMP: getvalue, validmodel, addtoexpr_reorder
using Base.Meta

export @polyvariable, @polyconstraint

function getvalue(p::VecPolynomial{JuMP.Variable})
  VecPolynomial(map(getvalue, p.a), p.x)
end
function getvalue(p::MatPolynomial{JuMP.Variable})
  MatPolynomial(map(getvalue, p.Q), p.x)
end

macro polyvariable(args...)
  length(args) <= 1 &&
  JuMP.variable_error(args, "Expected model as first argument, then variable information.")
  m = esc(args[1])
  x = args[2]
  extra = vcat(args[3:end]...)

  t = :Cont
  gottype = false
  haslb = false
  hasub = false
  # Identify the variable bounds. Five (legal) possibilities are "x >= lb",
  # "x <= ub", "lb <= x <= ub", "x == val", or just plain "x"
  if VERSION < v"0.5.0-dev+3231"
    x = comparison_to_call(x)
  end
  explicit_comparison = false
  if isexpr(x,:comparison) # two-sided
    JuMP.variable_error(args, "Polynomial variable declaration does not support the form lb <= ... <= ub. Use ... >= 0 and separate constraints instead.")
  elseif isexpr(x,:call)
    explicit_comparison = true
    if x.args[1] == :>= || x.args[1] == :≥
      # x >= lb
      var = x.args[2]
      @assert length(x.args) == 3
      lb = JuMP.esc_nonconstant(x.args[3])
      if lb != 0
        JuMP.variable_error(args, "Polynomial variable declaration does not support the form ... >= lb with nonzero lb.")
      end
      nonnegative = true
    elseif x.args[1] == :<= || x.args[1] == :≤
      # x <= ub
      # NB: May also be lb <= x, which we do not support
      #     We handle this later in the macro
      JuMP.variable_error(args, "Polynomial variable declaration does not support the form ... <= ub.")
    elseif x.args[1] == :(==)
      JuMP.variable_error(args, "Polynomial variable declaration does not support the form ... == value.")
    else
      # Its a comparsion, but not using <= ... <=
      JuMP.variable_error(args, "Unexpected syntax $(string(x)).")
    end
  else
    # No bounds provided - free variable
    # If it isn't, e.g. something odd like f(x), we'll handle later
    var = x
    nonnegative = false
  end

  # separate out keyword arguments
  kwargs = filter(ex->isexpr(ex,:kw), extra)
  extra = filter(ex->!isexpr(ex,:kw), extra)

  variable = gensym()
  quotvarname = quot(getname(var))
  escvarname  = esc(getname(var))

  monotype = :None

  # process keyword arguments
  gram = false
  for ex in kwargs
    kwarg = ex.args[1]
    if kwarg == :grammonomials
      if monotype != :None
        error("Monomials given twice")
      end
      monotype = :Gram
      x = esc(ex.args[2])
    elseif kwarg == :monomials
      if monotype != :None
        error("Monomials given twice")
      end
      monotype = :Classic
      x = esc(ex.args[2])
    else
      JuMP.variable_error(args, "Unrecognized keyword argument $kwarg")
    end
  end

  # Determine variable type (if present).
  # Types: default is continuous (reals)
  if isempty(extra)
    JuMP.variable_error(args, "Missing monomial vector")
  elseif length(extra) > 1
    JuMP.variable_error(args, "Too many extra argument: only expected monomial vector")
  else
    if monotype != :None
      error("Monomials given twice")
    end
    monotype = :Default
    x = esc(extra[1])
  end
  Z = gensym()

  if monotype == :None
    error("Monomials not given")
  end

  # This is ugly I know
  monotypeid = monotype == :Default ? 1 : (monotype == :Classic ? 2 : 3)

  if isa(var,Symbol)
    # Easy case - a single variable
    return JuMP.assert_validmodel(m, quote
        monotype = [:Default, :Classic, :Gram][$monotypeid]
        if $nonnegative
            $variable = createnonnegativepoly($m, $m.ext[:poly], monotype, $x)
        else
            $variable = createpoly($m, $m.ext[:poly], monotype, $x)
        end
        $escvarname = $variable
    end)
  else
    JuMP.variable_error(args, "Invalid syntax for variable name: $(string(var))")
  end
end

macro polyconstraint(m, x)
  m = esc(m)

  if isa(x, Symbol)
    error("in @polyconstraint: Incomplete constraint specification $x. Are you missing a comparison (<= or >=)?")
  end

  (x.head == :block) &&
  error("Code block passed as constraint.")
  if VERSION < v"0.5.0-dev+3231"
    x = comparison_to_call(x)
  end
  isexpr(x,:call) && length(x.args) == 3 || error("in @polyconstraint ($(string(x))): constraints must be in one of the following forms:\n" *
  "       expr1 <= expr2\n" * "       expr1 >= expr2")
  # Build the constraint
  # Simple comparison - move everything to the LHS
  sense = x.args[1]
  if sense == :⪰
    sense = :(>=)
  elseif sense == :⪯
    sense = :(<=)
  end
  sense,_ = JuMP._canonicalize_sense(sense)
  lhs = :()
  if sense == :(>=) || sense == :(==)
    lhs = :($(x.args[2]) - $(x.args[3]))
  elseif sense == :(<=)
    lhs = :($(x.args[3]) - $(x.args[2]))
  else
    error("Invalid sense $sense in polynomial constraint")
  end
  newaff, parsecode = JuMP.parseExprToplevel(lhs, :q)
  JuMP.assert_validmodel(m, quote
    q = zero(AffExpr)
    $parsecode
    if $sense == :(==)
      addpolyeqzeroconstraint($m, $m.ext[:poly], $newaff)
    else
      addpolynonnegativeconstraint($m, $m.ext[:poly], $newaff)
    end
  end)
end