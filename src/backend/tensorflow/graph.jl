using Base: @get!
using Flux: Reshape, MaxPool, flatten
using DataFlow: constant, Split
using DataFlow.Interpreter
using DataFlow.Interpreter: stack
using TensorFlow: RawTensor, TFException

# TODO: implement Julia's type promotion rules

node(x::Tuple) = map(node, x)
node(x::Tensor) = x
node(x::Variable) = x
node(x::Number) = TensorFlow.constant(Float32(x))

graph(::typeof(tuple), args...) = (args...,)
graph(s::Split, t::Tuple) = t[s.n]
graph(::typeof(getindex), t::Tuple, n::Integer) = t[n]
graph(::typeof(identity), x) = TensorFlow.identity(x)
graph(::typeof(softmax), x) = nn.softmax(x)
graph(::typeof(relu), x) = nn.relu(x)
graph(::typeof(σ), x) = nn.sigmoid(x)
graph(::typeof(hcat), xs...) = concat(1, xs)
graph(::typeof(sum), x, dim=nothing) = TensorFlow.reduce_sum(x;axis=dim)
graph(::typeof(prod), x, dim=nothing) = TensorFlow.reduce_prod(x;axis=dim)
graph(::typeof(min), x, dim=nothing) = TensorFlow.reduce_min(x;axis=dim)
graph(::typeof(max), x, dim=nothing) = TensorFlow.reduce_max(x;axis=dim)
graph(::typeof(all), x, dim=nothing) = TensorFlow.reduce_all(x;axis=dim)
graph(::typeof(any), x, dim=nothing) = TensorFlow.reduce_any(x;axis=dim)
graph(::typeof(mean), x, dim=nothing) = TensorFlow.reduce_mean(x;axis=dim)
graph(::typeof(svd), x) = svd(x)

for op in (*, .*, .+, .^, log, exp, ceil, floor, sqrt, abs, cos,
           sin, tan, atan, asin, acos, tanh, lgamma, erf, erfc, real, imag, conj,
           inv, det)
  @eval graph(::typeof($op), args...) = $op(args...)
end

for op in (+, -, *, /)
  @eval graph(::typeof(broadcast), ::typeof($op), args...) = broadcast($op, args...)
end

graph(::typeof(.-), args...) = -(args...)

graph(::typeof(map), f, xss::Tuple...) = map(f, xss...)

# reshape hack due to https://github.com/malmaud/TensorFlow.jl/issues/79
batchsize(x::Tensor) = reduce_sum(slice(TensorFlow.shape(x), [0], [1]))
graph(::typeof(flatten), x) = reshape(x, pack([batchsize(x), Int32(-1)]))
graph(r::Reshape, x) = reshape(x, pack([batchsize(x), map(Int32, r.dims)...]))

graph(::Input, x) = x

graph(p::MaxPool, x) =
  nn.max_pool(x, [1, p.size..., 1], [1, p.stride..., 1], "VALID")

graph(op::Op, xs...) = op.f(xs...)

function graph(ctx::Context, model, args...)
  node = graph(model, args...)
  node isa Tensor && (ctx[:stacks][node.op.name] = stack(ctx))
  return node
end

interp(ctx, c::Conv2D, x) =
  nn.conv2d(x, interp(ctx, constant(c.filter)), [1,c.stride...,1], "VALID")

param(ctx, p::Flux.Param{<:AbstractArray}) =
  haskey(ctx[:params], p) ?
     ctx[:params][p] :
    (ctx[:params][p] =
       ctx[:variables] ?
        Variable(Float32.(p.x)) :
        placeholder(Float32))

param(ctx, x) = x

function interp(ctx, model, args...)
  args = param.(ctx, args)
  g = Flux.graph(model)
  g == nothing && return graph(ctx, model, args...)
  DataFlow.iscyclic(g) && error("This model has a cycle; try unrolling it first.")
  interpret(ctx, g, args...)
end

function tograph(model, args...; variables = false)
  ctx = Context(mux(iline, iconst, ilambda, iargs, ituple, interp),
                params = ObjectIdDict(), stacks = Dict(), variables = variables)
  out = interp(ctx, model, map(constant, args)...)
  return ctx[:params], ctx[:stacks], out
end

astensor(model, args...) =
  tograph(model, args...; variables = true)[3]

RawTensor(data::Union{Flux.Batch,Flux.Seq}) = RawTensor(Flux.rawbatch(data))

# Error Handling

using Juno
using MacroTools: @q
using DataFlow.Interpreter: Exception, totrace
Juno.errmsg(e::TFException) = string(e.status)

function errnode(e::TFException)
  m = match(r"Node: ([\w\d]+) =", string(e.status))
  m == nothing && return
  m.captures[1]
end

errnode(e) = nothing

macro tferr(stk, ex)
  @q try
    $(esc(ex))
  catch e
    (node = errnode(e)) != nothing || rethrow()
    stk = $(esc(stk))
    haskey(stk, node) || rethrow()
    throw(Exception(e, totrace(stk[node])))
  end
end
