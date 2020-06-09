"""
    KissABC
Module to perform approximate bayesian computation,

Simple Example:
inferring the mean of a `Normal` distribution
```julia
using KissABC
using Distributions

prior=Normal(0,1)
data=randn(1000) .+ 1
sim(μ,other)=randn(1000) .+ μ
dist(x,y) = abs(mean(x) - mean(y))

plan=ABCplan(prior, sim, data, dist)
μ_post,Δ = ABCDE(plan, 1e-2)
@show mean(μ_post) ≈ 1.0
```

for more complicated code examples look at `https://github.com/francescoalemanno/KissABC.jl/`
"""
module KissABC

using Base.Threads
using Distributions
using Random


"""
    ABCplan(prior, simulation, data, distance; params=())

Builds a type `ABCplan` which holds

# Arguments:
- `prior`: a `Distribution` to use for sampling candidate parameters
- `simulation`: simulation function `sim(prior_sample, constants) -> data` that accepts a prior sample and the `params` constant and returns a simulated dataset
- `data`: target dataset which must be compared with simulated datasets
- `distance`: distance function `dist(x,y)` that return the distance (a scalar value) between `x` and `y`
- `params`: an optional set of constants to be passed as second argument to the simulation function
"""
struct ABCplan{T1,T2,T3,T4,T5}
    prior::T1
    simulation::T2
    data::T3
    distance::T4
    params::T5
    ABCplan(prior::T1,simulation::T2,data::T3,distance::T4;params::T5=()) where {T1,T2,T3,T4,T5} = new{T1,T2,T3,T4,T5}(prior,simulation,data,distance,params)
end

macro cthreads(condition::Symbol,loop) #does not work well because of #15276, but seems to work on Julia v0.7
    return esc(quote
        if $condition
            Threads.@threads $loop
        else
            $loop
        end
    end)
end

macro extract_params(S,params...)
    c=:()
    for p in params
        c=quote
            $c
            $p = $S.$p
        end
    end
    esc(c)
end

import Distributions.pdf, Random.rand, Base.length
struct MixedSupport <: ValueSupport; end

"""
    Factored{N} <: Distribution{Multivariate, MixedSupport}

a `Distribution` type that can be used to combine multiple `UnivariateDistribution`'s and sample from them.

Example: it can be used as `prior = Factored(Normal(0,1), Uniform(-1,1))`
"""
struct Factored{N}<:Distribution{Multivariate,MixedSupport}
    p::NTuple{N,UnivariateDistribution}
    Factored(args::UnivariateDistribution...) = new{length(args)}(args)
end
"""
    pdf(d::Factored, x) = begin

Function to evaluate the pdf of a `Factored` distribution object
"""
pdf(d::Factored,x) = prod(i->pdf(d.p[i],x[i]),eachindex(x))

"""
    rand(rng::AbstractRNG, factoreddist::Factored)

function to sample one element from a `Factored` object
"""
rand(rng::AbstractRNG,factoreddist::Factored) = rand.(Ref(rng),factoreddist.p)

"""
    length(p::Factored) = begin

returns the number of distributions contained in `p`.
"""
length(p::Factored) = sum(length.(p.p))

function compute_kernel_scales(prior::Factored,V)
    l = length(V[1])
    ntuple(i -> compute_kernel_scales(prior.p[i],getindex.(V,i)),l)
end

function compute_kernel_scales(prior::DiscreteDistribution,V)
    #a,b = extrema(V)
    #ceil(Int,(b - a) /sqrt(3))
    ceil(Int,sqrt(2)*std(V))
end

function compute_kernel_scales(prior::ContinuousDistribution,V)
    sqrt(2)*std(V)
end

function kernel(prior::DiscreteDistribution,c,scale)
    truncated(DiscreteUniform(c-scale,c+scale),minimum(prior),maximum(prior))
end

function kernel(prior::ContinuousDistribution,c,scale)
    truncated(Normal(c,scale),minimum(prior),maximum(prior))
end

function perturb(prior::Factored,scales,sample)
    l=length(sample)
    ntuple(i -> perturb(prior.p[i],scales[i],sample[i]),l)
end

function perturb(prior::Distribution,scales,sample)
    return rand(kernel(prior,sample,scales))
end

function kerneldensity(prior::Factored,scales,s1,s2)
    prod(i -> kerneldensity(prior.p[i],scales[i],s1[i],s2[i]),eachindex(s1,s2,scales))
end

function kerneldensity(prior::Distribution,scales,s1,s2)
    return pdf(kernel(prior,s1,scales),s2)
end

"""
    sample_plan(plan::ABCplan, nparticles, parallel)

function to sample the prior distribution of both parameters and distances.

# Arguments:
- `plan`: a plan built using the function ABCplan.
- `nparticles`: number of samples to draw.
- `parallel`: enable or disable threaded parallelism via `true` or `false`.
"""
function sample_plan(plan::ABCplan,nparticles,parallel)
    θs=[rand(plan.prior) for i in 1:nparticles]
    Δs=fill(plan.distance(plan.data, plan.data),nparticles)
    @cthreads parallel for i in 1:nparticles
        x=plan.simulation(θs[i],plan.params)
        Δs[i]=plan.distance(x,plan.data)
    end
    θs,Δs
end

function ABCSMCPR(plan::ABCplan, ϵ_target;
                  nparticles=100, maxsimpp=1e3, α=0.3, c=0.01, parallel=false, verbose=true)
    # https://doi.org/10.1111/j.1541-0420.2010.01410.x
    @extract_params plan prior distance simulation data params
    Nα=ceil(Int,α*nparticles)
    @assert 2<Nα<nparticles-1
    maxsimulations=nparticles*maxsimpp
    θs,Δs=sample_plan(plan,nparticles,parallel)
    numsim=Atomic{Int}(nparticles)
    numaccepted=Atomic{Int}(Nα)
    Rt=ceil(Int,log(c)/log(1.0-α))
    while true
        sp=sortperm(Δs)
        ϵ_current=Δs[sp[Nα]]
        idx_alive=sp[1:Nα]
        idx_dead=sp[Nα+1:end]
        scale=compute_kernel_scales(prior,θs[idx_dead])
        past_sim=numsim[]
        past_accepted=numaccepted[]
        @cthreads parallel for i in idx_dead
            local_nsims=0
            local_accept=0
            j=rand(idx_alive)
            θs[i]=θs[j]
            Δs[i]=Δs[j]
            for reps in 1:Rt
                θp=perturb(prior,scale,θs[i])
                w_prior=pdf(prior,θp)/pdf(prior,θs[i])
                w_kd=kerneldensity(prior,scale,θp,θs[i])/kerneldensity(prior,scale,θs[i],θp)
                w=min(1,w_prior*w_kd)
                rand()>w && continue
                xp=simulation(θp,params)
                local_nsims+=1
                dp=distance(xp,data)
                dp > ϵ_current && continue
                θs[i]=θp
                Δs[i]=dp
                local_accept+=1
            end
            atomic_add!(numsim,local_nsims)
            atomic_add!(numaccepted,local_accept)
        end
        current_sim=(numsim[]-past_sim)
        current_accepted=(numaccepted[]-past_accepted)
        acceptance_rate=(current_accepted+0.1)/(Rt*length(idx_dead)+0.2)
        if verbose
            @info  "Finished run" ϵ_current acceptance_rate simulations=numsim[] Rt early_rejected=1-current_sim/(Rt*length(idx_dead))
        end
        Rt=ceil(Int,log(c)/log(1.0-acceptance_rate))

        ϵ_current<=ϵ_target && break
        numsim[]+Rt*length(idx_dead)>maxsimulations && break
    end
    if verbose
        if ϵ_target < maximum(Δs)
            @warn "Failed to reach target ϵ.\n   possible fix: increase maximum number of simulations"
        end
    end
    θs,Δs
end

function deperturb(prior::Factored,sample,r1,r2,γ)
    deperturb.(prior.p,sample,r1,r2,γ)
end

function deperturb(prior::ContinuousUnivariateDistribution,sample,r1,r2,γ)
    p = (r1-r2)*γ*(rand()*0.2+0.9) + 0.05*randn()*abs(r1-r2)
    sample + p
end

function deperturb(prior::DiscreteUnivariateDistribution,sample::T,r1,r2,γ) where T
    p = (r1-r2)*γ*(rand()*0.2+0.9) + randn()*max(0.05*abs(r1-r2),0.5)
    sp=sign(p)
    ap=abs(p)
    intp=floor(ap)
    floatp=ap-intp
    pprob=(intp+ifelse(rand()>floatp,oftype(p,0),oftype(p,1)))*sp
    sample + round(T,pprob)
end

function ABCDE_innerloop(plan::ABCplan,ϵ,θs,Δs,idx,parallel)
    @extract_params plan prior distance simulation data params
    nθs=copy(θs)
    nΔs=copy(Δs)
    nparticles=length(θs)
    γ = 2.38/sqrt(2*length(prior))
    @cthreads parallel for i in idx
        a=rand(1:nparticles)
        b=a
        while b==a
            b=rand(1:nparticles)
        end
        c=a
        while c==a || c==b
            c=rand(1:nparticles)
        end
        θp=deperturb(prior,θs[a],θs[b],θs[c],γ)
        w_prior=pdf(prior,θp)/pdf(prior,θs[i])
        w=min(1,w_prior)
        rand()>w && continue
        xp=simulation(θp,params)
        dp=distance(xp,data)
        if dp<ϵ || dp < Δs[i]
            nΔs[i]=dp
            nθs[i]=θp
        end
    end
    nθs,nΔs
end

function ABCDE(plan::ABCplan, ϵ_target;
                  nparticles=100, maxsimpp=200, parallel=false, α=1/3, mcmcsteps=0, verbose=true)
    # simpler version of https://doi.org/10.1016/j.jmp.2012.06.004
    @extract_params plan prior distance simulation data params
    @assert 0<α<1 "α must be strictly between 0 and 1."
    θs,Δs=sample_plan(plan,nparticles,parallel)
    nsim=nparticles
    ϵ_current=max(ϵ_target,mean(extrema(Δs)))+1
    while maximum(Δs)>ϵ_target && nsim < maxsimpp*nparticles
        ϵ_past=ϵ_current
        ϵ_current=max(ϵ_target,sum(extrema(Δs).*(1-α,α)))
        idx=(1:nparticles)[Δs.>ϵ_current]
        θs,Δs=ABCDE_innerloop(plan, ϵ_current, θs, Δs, idx, parallel)
        nsim+=length(idx)
        if verbose && ϵ_current!=ϵ_past
            @info "Finished run:" completion=1-sum(Δs.>ϵ_target)/nparticles num_simulations=nsim ϵ=ϵ_current
        end
    end
    ϵ_current=maximum(Δs)
    verbose && @info "ABCDE Ended:" completion=1-sum(Δs.>ϵ_target)/nparticles num_simulations=nsim ϵ=ϵ_current
    converged = true
    if ϵ_target < ϵ_current
        verbose && @warn "Failed to reach target ϵ.\n   possible fix: increase maximum number of simulations"
        converged = false
    end

    if mcmcsteps>0 && converged
        verbose && @info "Performing additional MCMC-DE steps at tolerance " ϵ_current
        for i in 1:mcmcsteps
            nθs,nΔs=ABCDE_innerloop(plan, ϵ_current, θs[end-nparticles+1:end], Δs[end-nparticles+1:end], 1:nparticles, parallel)
            append!(θs,nθs)
            append!(Δs,nΔs)
            if verbose
                @info "Finished step:" i remaining_steps=mcmcsteps-i
            end
        end
    end
    θs, Δs, converged
end

function ABC(plan::ABCplan, α_target;
             nparticles=100, parallel=false)
    @extract_params plan prior distance simulation data params
    @assert 0<α_target<=1 "α_target is the acceptance rate, and must be properly set between 0 - 1."
    simparticles=ceil(Int,nparticles/α_target)
    @show simparticles
    particles,distances=sample_plan(plan,simparticles,parallel)
    idx=sortperm(distances)[1:nparticles]
    (particles=particles[idx],
     distances=distances[idx],
     ϵ=distances[idx[end]])
end

export ABCplan, ABC, ABCSMCPR, ABCDE, Factored, sample_plan


"""
    compute_kernel_scales(prior::Distribution, V)

Function for `ABCSMCPR` whose purpose is to compute the characteristic scale of the perturbation
kernel appropriate for `prior` given the Vector `V` of parameters
"""
compute_kernel_scales

"""
    kernel(prior::Distribution, c, scale)

Function for `ABCSMCPR` whose purpose is returning the appropriate `Distribution` to use as a perturbation kernel on sample `c` and characteristic `scale`

# Arguments:
- `prior`: prior distribution
- `c`: sample acting as center of perturbation kernel
- `scale`: characteristic scale of perturbation kernel
"""
kernel

"""
    perturb(prior::Distribution, scales, sample)

Function for `ABCSMCPR` whose purpose is perturbing `sample` according to the appropriate `kernel` for `prior` with characteristic `scales`.
"""
perturb

"""
    kerneldensity(prior::Distribution, scales, s1, s2)

Function for `ABCSMCPR` whose purpose is returning the probability density of observing `s2` under the kernel centered on `s1` with scales given by `scales` and appropriate for `prior`.
"""
kerneldensity

"""
    ABCSMCPR(prior, simulation, data, distance, ϵ_target; nparticles = 100, maxsimpp = 1000.0, α = 0.3, c = 0.01, parallel = false, params = (), verbose = true)

Sequential Monte Carlo algorithm (Drovandi et al. 2011, https://doi.org/10.1111/j.1541-0420.2010.01410.x).

# Arguments:
- `plan`: a plan built using the function ABCplan.
- `ϵ_target`: maximum acceptable distance between simulated datasets and the target dataset
- `nparticles`: number of samples from the approximate posterior that will be returned
- `maxsimpp`: average maximum number of simulations per particle
- `α`: proportion of particles to retain at every iteration of SMC, other particles are resampled
- `c`: probability that a sample will not be updated during one iteration of SMC
- `parallel`: when set to `true` multithreaded parallelism is enabled
- `verbose`: when set to `true` verbosity is enabled
"""
ABCSMCPR


"""
    ABCDE(prior, simulation, data, distance, ϵ_target; α=1/3, nparticles = 100, maxsimpp = 200, mcmcsteps=0, parallel = false, params = (), verbose = true)

A sequential monte carlo algorithm inspired by differential evolution, work in progress, very efficient (simpler version of B.M.Turner 2012, https://doi.org/10.1016/j.jmp.2012.06.004)

# Arguments:
- `plan`: a plan built using the function ABCplan.
- `ϵ_target`: maximum acceptable distance between simulated datasets and the target dataset
- `α`: the adaptive ϵ at every iteration is chosen as `ϵ → m*(1-α)+M*α` where `m` and `M` are respectively minimum and maximum distance of current population.
- `nparticles`: number of samples from the approximate posterior that will be returned
- `maxsimpp`: average maximum number of simulations per particle
- `mcmcsteps`: option to sample more than `1` population of `nparticles`, the end population will contain `(1 + mcmcsteps) * nparticles` total particles
- `parallel`: when set to `true` multithreaded parallelism is enabled
- `verbose`: when set to `true` verbosity is enabled
"""
ABCDE


"""
    deperturb(prior::Distribution, sample, r1, r2, γ)

Function for `ABCDE` whose purpose is computing `sample + γ (r1 - r2) + ϵ` (the perturbation function of differential evolution) in a way suited to the prior.

# Arguments:
- `prior`
- `sample`
- `r1`
- `r2`
"""
deperturb


"""
    ABC(prior, simulation, data, distance, α_target; nparticles = 100, params = (), parallel = false)

Classical ABC rejection algorithm.

# Arguments:
- `plan`: a plan built using the function ABCplan.
- `α_target`: target acceptance rate for ABC rejection algorithm, `nparticles/α` will be sampled and only the best `nparticles` will be retained.
- `nparticles`:  number of samples from the approximate posterior that will be returned
- `parallel`: when set to `true` multithreaded parallelism is enabled
"""
ABC

end
