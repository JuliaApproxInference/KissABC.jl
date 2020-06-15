
function compute_kernel_scales(prior::Factored{N},V) where N
    ntuple(i -> compute_kernel_scales(prior.p[i],getindex.(V,i)),Val(N))
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

function perturb(prior::Factored{N},scales,sample) where N
    ntuple(i -> perturb(prior.p[i],scales[i],sample[i]),Val(N))
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
    ABCSMCPR(plan, ϵ_target; nparticles = 100, maxsimpp = 1000.0, α = 0.3, c = 0.01, parallel = false, verbose = true)

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
