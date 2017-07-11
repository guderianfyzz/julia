# This file is a part of Julia. License is MIT: https://julialang.org/license

# Arrays of random numbers

## AbstractRNG

rand(r::AbstractRNG, dims::Dims)       = rand(r, Float64, dims)
rand(                dims::Dims)       = rand(GLOBAL_RNG, dims)
rand(r::AbstractRNG, dims::Integer...) = rand(r, convert(Dims, dims))
rand(                dims::Integer...) = rand(convert(Dims, dims))

rand(r::AbstractRNG, T::Type, dims::Dims)                    = rand!(r, Array{T}(dims))
rand(                T::Type, dims::Dims)                    = rand(GLOBAL_RNG, T, dims)
rand(r::AbstractRNG, T::Type, d1::Integer, dims::Integer...) = rand(r, T, tuple(Int(d1), convert(Dims, dims)...))
rand(                T::Type, d1::Integer, dims::Integer...) = rand(T, tuple(Int(d1), convert(Dims, dims)...))
# note: the above method would trigger an ambiguity warning if d1 was not separated out:
# rand(r, ()) would match both this method and rand(r, dims::Dims)
# moreover, a call like rand(r, NotImplementedType()) would be an infinite loop

function rand!(r::AbstractRNG, A::AbstractArray{T}, ::Type{X}=T) where {T,X}
    for i in eachindex(A)
        @inbounds A[i] = rand(r, X)
    end
    A
end

rand!(A::AbstractArray{T}, ::Type{X}=T) where {T,X} = rand!(GLOBAL_RNG, A, X)

## MersenneTwister

function rand_AbstractArray_Float64!(r::MersenneTwister, A::AbstractArray{Float64},
                                     n=length(A), ::Type{I}=CloseOpen) where I<:FloatInterval
    # what follows is equivalent to this simple loop but more efficient:
    # for i=1:n
    #     @inbounds A[i] = rand(r, I)
    # end
    m = 0
    while m < n
        s = mt_avail(r)
        if s == 0
            gen_rand(r)
            s = mt_avail(r)
        end
        m2 = min(n, m+s)
        for i=m+1:m2
            @inbounds A[i] = rand_inbounds(r, I)
        end
        m = m2
    end
    A
end

rand!(r::MersenneTwister, A::AbstractArray{Float64}) = rand_AbstractArray_Float64!(r, A)

fill_array!(s::DSFMT_state, A::Ptr{Float64}, n::Int, ::Type{CloseOpen}) = dsfmt_fill_array_close_open!(s, A, n)
fill_array!(s::DSFMT_state, A::Ptr{Float64}, n::Int, ::Type{Close1Open2}) = dsfmt_fill_array_close1_open2!(s, A, n)

function rand!(r::MersenneTwister, A::Array{Float64}, n::Int=length(A), ::Type{I}=CloseOpen) where I<:FloatInterval
    # depending on the alignment of A, the data written by fill_array! may have
    # to be left-shifted by up to 15 bytes (cf. unsafe_copy! below) for
    # reproducibility purposes;
    # so, even for well aligned arrays, fill_array! is used to generate only
    # the n-2 first values (or n-3 if n is odd), and the remaining values are
    # generated by the scalar version of rand
    if n > length(A)
        throw(BoundsError(A,n))
    end
    n2 = (n-2) ÷ 2 * 2
    if n2 < dsfmt_get_min_array_size()
        rand_AbstractArray_Float64!(r, A, n, I)
    else
        pA = pointer(A)
        align = Csize_t(pA) % 16
        if align > 0
            pA2 = pA + 16 - align
            fill_array!(r.state, pA2, n2, I) # generate the data in-place, but shifted
            unsafe_copy!(pA, pA2, n2) # move the data to the beginning of the array
        else
            fill_array!(r.state, pA, n2, I)
        end
        for i=n2+1:n
            @inbounds A[i] = rand(r, I)
        end
    end
    A
end

@inline mask128(u::UInt128, ::Type{Float16}) = (u & 0x03ff03ff03ff03ff03ff03ff03ff03ff) | 0x3c003c003c003c003c003c003c003c00
@inline mask128(u::UInt128, ::Type{Float32}) = (u & 0x007fffff007fffff007fffff007fffff) | 0x3f8000003f8000003f8000003f800000

function rand!(r::MersenneTwister, A::Union{Array{Float16},Array{Float32}}, ::Type{Close1Open2})
    T = eltype(A)
    n = length(A)
    n128 = n * sizeof(T) ÷ 16
    rand!(r, unsafe_wrap(Array, convert(Ptr{Float64}, pointer(A)), 2*n128), 2*n128, Close1Open2)
    A128 = unsafe_wrap(Array, convert(Ptr{UInt128}, pointer(A)), n128)
    @inbounds for i in 1:n128
        u = A128[i]
        u ⊻= u << 26
        # at this point, the 64 low bits of u, "k" being the k-th bit of A128[i] and "+" the bit xor, are:
        # [..., 58+32,..., 53+27, 52+26, ..., 33+7, 32+6, ..., 27+1, 26, ..., 1]
        # the bits needing to be random are
        # [1:10, 17:26, 33:42, 49:58] (for Float16)
        # [1:23, 33:55] (for Float32)
        # this is obviously satisfied on the 32 low bits side, and on the high side, the entropy comes
        # from bits 33:52 of A128[i] and then from bits 27:32 (which are discarded on the low side)
        # this is similar for the 64 high bits of u
        A128[i] = mask128(u, T)
    end
    for i in 16*n128÷sizeof(T)+1:n
        @inbounds A[i] = rand(r, T) + oneunit(T)
    end
    A
end

function rand!(r::MersenneTwister, A::Union{Array{Float16},Array{Float32}}, ::Type{CloseOpen})
    rand!(r, A, Close1Open2)
    I32 = one(Float32)
    for i in eachindex(A)
        @inbounds A[i] = Float32(A[i])-I32 # faster than "A[i] -= one(T)" for T==Float16
    end
    A
end

rand!(r::MersenneTwister, A::Union{Array{Float16},Array{Float32}}) = rand!(r, A, CloseOpen)

function rand!(r::MersenneTwister, A::Array{UInt128}, n::Int=length(A))
    if n > length(A)
        throw(BoundsError(A,n))
    end
    Af = unsafe_wrap(Array, convert(Ptr{Float64}, pointer(A)), 2n)
    i = n
    while true
        rand!(r, Af, 2i, Close1Open2)
        n < 5 && break
        i = 0
        @inbounds while n-i >= 5
            u = A[i+=1]
            A[n]    ⊻= u << 48
            A[n-=1] ⊻= u << 36
            A[n-=1] ⊻= u << 24
            A[n-=1] ⊻= u << 12
            n-=1
        end
    end
    if n > 0
        u = rand_ui2x52_raw(r)
        for i = 1:n
            @inbounds A[i] ⊻= u << 12*i
        end
    end
    A
end

# A::Array{UInt128} will match the specialized method above
function rand!(r::MersenneTwister, A::Base.BitIntegerArray)
    n = length(A)
    T = eltype(A)
    n128 = n * sizeof(T) ÷ 16
    rand!(r, unsafe_wrap(Array, convert(Ptr{UInt128}, pointer(A)), n128))
    for i = 16*n128÷sizeof(T)+1:n
        @inbounds A[i] = rand(r, T)
    end
    A
end

## BitArray

function rand!(rng::AbstractRNG, B::BitArray)
    isempty(B) && return B
    Bc = B.chunks
    rand!(rng, Bc)
    Bc[end] &= Base._msk_end(B)
    return B
end

"""
    bitrand([rng=GLOBAL_RNG], [dims...])

Generate a `BitArray` of random boolean values.

# Example

```jldoctest
julia> rng = MersenneTwister(1234);

julia> bitrand(rng, 10)
10-element BitArray{1}:
  true
  true
  true
 false
  true
 false
 false
  true
 false
  true
```
"""
bitrand(r::AbstractRNG, dims::Dims)   = rand!(r, BitArray(dims))
bitrand(r::AbstractRNG, dims::Integer...) = rand!(r, BitArray(convert(Dims, dims)))

bitrand(dims::Dims)   = rand!(BitArray(dims))
bitrand(dims::Integer...) = rand!(BitArray(convert(Dims, dims)))
