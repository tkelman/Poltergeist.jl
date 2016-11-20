export Transfer

abstract AbstractTransfer{T} <: Operator{T}

ApproxFun.israggedbelow(L::AbstractTransfer) = true
Base.issymmetric(L::AbstractTransfer) = false

#for OP in (:(ApproxFun.domain),:rangedomain)
#    @eval $OP(L::AbstractTransfer) = $OP(getmap(L))
#end

Transfer(stuff...) = cache(ConcreteTransfer(stuff...))

# fast colstop for transfer operators
function ApproxFun.colstop{T<:Number,M<:AbstractTransfer,DS,RS}(B::ApproxFun.CachedOperator{T,RaggedMatrix{T},M,DS,RS,Tuple{Infinity{Bool}}},k::Integer)
  ApproxFun.resizedata!(B,:,k)
  B.data.cols[k+1] - B.data.cols[k]
end

immutable ConcreteTransfer{T,D<:Space,R<:Space,M<:AbstractMarkovMap} <: AbstractTransfer{T}
  m::M
  domainspace::D #Domain space
  rangespace::R
  colstops::Array{Int,1}
  #    f::Array{Vector{T},1}
  function ConcreteTransfer(m::AbstractMarkovMap,domainspace::Space,rangespace::Space)
    @assert domain(m)==domain(domainspace)
    @assert rangedomain(m)==domain(rangespace)
    nneutral(m) != 0 && error("Neutral fixed points not supported for transfer operator")
    new{eltype(m),typeof(domainspace),typeof(rangespace),typeof(m)}(m,domainspace,rangespace,eltype(M)[])
  end
end

ConcreteTransfer{T}(::Type{T},m::AbstractMarkovMap,dom::Space=Space(domain(m)),
                    ran::Space=(domain(m)==rangedomain(m) ? dom : Space(rangedomain(m)))) =
  ConcreteTransfer{T,typeof(dom),typeof(ran),typeof(m)}(m,dom,ran)#,domainspace(m),rangespace(m))

for OP in (:domainspace,:rangespace)
  @eval ApproxFun.$OP(L::ConcreteTransfer) = L.$OP
end

getmap(L::ConcreteTransfer) = L.m

Transfer{T}(::Type{T},m::AbstractMarkovMap,dom::Space=Space(domain(m)),
            ran::Space=(domain(m)==rangedomain(m) ? dom : Space(rangedomain(m)))) = cache(ConcreteTransfer(T,m,dom,ran),padding=true)
Transfer(m::AbstractMarkovMap,dom::Space=Space(domain(m)),
         ran::Space=(domain(m)==rangedomain(m) ? dom : Space(rangedomain(m)))) = cache(ConcreteTransfer(eltype(m),m,dom,ran),padding=true)

function resizecolstops!(L::ConcreteTransfer,n)
  colstopslength = length(L.colstops)
  if n > colstopslength
    append!(L.colstops,-ones(Int,n-colstopslength)) #-1 is clunky but w/e
  end
end

function setcolstops!(L::ConcreteTransfer,inds,vals) #should be generic range/collection I guess?
  resizecolstops!(L,maximum(inds))
  L.colstops[inds] = vals
end

chebyTk(x,d,k::Integer) = cos((k-1)*acos(tocanonical(d,x))) #roundoff error grows linearly(??) with k may not be bad wrt x too
function transferfunction{TT,D}(x,L::ConcreteTransfer{TT,Chebyshev{D}},k::Integer,T)
  y = zero(x);

  for b in branches(getmap(L))
    if isa(b,FwdExpandingBranch)
      mapinvx = mapinv(b,x)
      y += abs(1/unsafe_mapD(b,mapinvx)).*chebyTk(mapinvx,domain(L),k)
    else
      y += abs(mapinvD(b,x)).*chebyTk(mapinv(b,x),domain(L),k)
    end
  end;
  abs(y) < 20k*eps(one(abs(y))) ? zero(y) : y
end

fourierCSk(x,d,k::Integer) = rem(k,2) == 1 ? cos(fld(k,2)*tocanonical(d,x)) : sin(fld(k,2)*tocanonical(d,x))
function transferfunction{TT,D}(x,L::ConcreteTransfer{TT,Fourier{D}},k::Integer,T)
  y = zero(x);

  for b in branches(getmap(L))
    if isa(b,FwdExpandingBranch)
      mapinvx = mapinv(b,x)
      y += abs(1/unsafe_mapD(b,mapinvx)).*fourierCSk(mapinvx,domain(L),k)
    else
      y += abs(mapinvD(b,x)).*fourierCSk(mapinv(b,x),domain(L),k)
    end
  end;
  abs(y) < 20k*eps(one(abs(y))) ? zero(y) : y

end


function default_transferfunction{TT,DD}(x,L::ConcreteTransfer{TT,DD},kk::Integer,T)
  y = zero(x);
  fn = Fun([zeros(T,kk-1);one(T)],domainspace(L));

  for b in branches(getmap(L))
    if isa(b,FwdExpandingBranch)
      mapinvx = mapinv(b,x)
      y += abs(1/unsafe_mapD(b,mapinvx)).*fn(mapinvx)
    else
      y += abs(mapinvD(b,x)).*fn(mapinv(b,x))
    end
  end;

  abs(y) < 200eps(one(abs(y))) ? zero(y) : y
end
transferfunction(x,L,kk,T) = default_transferfunction(x,L,kk,T)

# Indexing

transferfunction_nodes{TT,D,R,M<:AbstractMarkovMap}(L::ConcreteTransfer{TT,D,R,M},n::Integer,kk,T) =
  [transferfunction(p,L,kk,T) for p in points(rangespace(L),n)]
transferfunction_nodes{TT,D,R,M<:MarkovInverseCache}(L::ConcreteTransfer{TT,D,R,M},n::Integer,kk,T) =
  [transferfunction(InterpolationNode(rangespace(getmap(L)),k,n),L,kk,T) for k = 1:n]


function transfer_getindex{T}(L::ConcreteTransfer{T},jdat::Tuple{Integer,Integer,Union{Integer,Infinity{Bool}}},k::Range,padding::Bool=false)
  #T = eltype(getmap(L))
  dat = Array(T,0)
  cols = Array(eltype(k),Base.length(k)+1)
  cols[1] = 1
  K = isfinite(jdat[3]) ? length(jdat[1]:jdat[2]:jdat[3]) : 0 # largest colstop
  padding && start(k) > 1 && (K = max(maximum([colstop(L,i) for i =1:start(k)-1]),K))
  rs = rangespace(L)

  resizecolstops!(L,maximum(k))
  mc = maximum(L.colstops[1:first(k)])

  for (kind,kk) in enumerate(k)
    kind > 1 && (mc = max(mc,maximum(L.colstops[k[kind-1]+1:kk])))

    #    f(x) = transferfunction(x,L,kk,T)
    tol =T==Any?200eps():200eps(T)

    if L.colstops[kk] >= 1
      coeffs = ApproxFun.transform(rs,transferfunction_nodes(L,2^max(4,convert(Int,ceil(log2(L.colstops[kk])))),kk,T))
      maxabsc = maxabs(coeffs)
      chop!(coeffs,tol*maxabsc*log2(length(coeffs))/10)
    elseif L.colstops[kk]  == 0
      coeffs = [0.]
    else

      #       if mc ≤ 2^4
      #         coeffs = Fun(f,rs).coefficients
      #       else
      # code from ApproxFun (src/Fun/constructors.jl) - the difference is we start at n \approx mc

      r=ApproxFun.checkpoints(rs)
      fr=[transferfunction(rr,L,kk,T) for rr in r]
      maxabsfr=norm(fr,Inf)

      logn = min(convert(Int,ceil(log2(max(mc,16)))),20)
      while logn < 21
        coeffs = ApproxFun.transform(rs,transferfunction_nodes(L,2^logn,kk,T))

        maxabsc = maxabs(coeffs)
        if maxabsc == 0 && maxabsfr == 0
          coeffs = [0.]
          break
        else
          b = ApproxFun.block(rs,length(coeffs))
          bs = ApproxFun.blockstart(rs,max(b-2,1))
          if length(coeffs) > 8 && maxabs(coeffs[bs:end]) < tol*maxabsc*logn &&
              all(kkk->norm(Fun(coeffs,rs)(r[kkk])-fr[kkk],1)<tol*length(coeffs)*maxabsfr*1000,1:length(r))
            chop!(coeffs,tol*maxabsc*logn/10)
            break
          end
        end
        logn += 1
      end

      if logn == 21
        warn("Maximum number of coefficients "*string(2^20+1)*" reached in constructing $(k)th column.")
        coeffs = ApproxFun.transform(rs,transferfunction_nodes(L,2^logn,kk,T))
      end

    end

    #    tol = 4ceil(log2(length(tk.coefficients)))*eps(T) # 4 is dummy should be like 1 in Fourier, 2C+1 in Cheby
    #    chop!(tk,tol)
    maxabsc = maxabs(coeffs)
    lcfc = length(coeffs)

    for i = 1:lcfc
      abs(coeffs[i])<tol*maxabsc*log2(lcfc)/10 && (coeffs[i] = 0)
    end

    cutcfc = coeffs[(jdat[1]:jdat[2]:min(lcfc,jdat[3]))::Range]

    K = max(K,length(cutcfc))
    padding && ApproxFun.pad!(cutcfc,K)
    append!(dat,cutcfc)
    cols[kind+1] = cols[kind]+length(cutcfc)

    setcolstops!(L,kk,lcfc)
    #   kk == 1 && display(stacktrace())
  end
  RaggedMatrix(dat,cols,K)
end

Base.getindex(L::ConcreteTransfer,j::Range,k::Range) = transfer_getindex(L,(start(j),step(j),last(j)),k)
Base.getindex(L::ConcreteTransfer,j::Colon,k::Range) = transfer_getindex(L,(1,1,ApproxFun.∞),k)
Base.getindex(L::ConcreteTransfer,j::ApproxFun.AbstractCount,k::Range) = transfer_getindex(L,(start(j),step(j),ApproxFun.∞),k)
Base.getindex(L::ConcreteTransfer,j::Integer,k::Integer) = Base.getindex(L,j:j,k:k)[1,1]
Base.getindex(L::ConcreteTransfer,j::Integer,k::Range) = Base.getindex(L,j:j,k).data
Base.getindex(L::ConcreteTransfer,j::Range,k::Integer) = Base.getindex(L,j,k:k).data

function ApproxFun.default_raggedmatrix{T,LL<:AbstractTransfer,R1<:Union{Range,ApproxFun.AbstractCount},R2<:Range}(
    S::ApproxFun.SubOperator{T,LL,Tuple{R1,R2}})
  Base.getindex(parent(S),parentindexes(S)[1],parentindexes(S)[2])
end



function ApproxFun.colstop(L::ConcreteTransfer,k::Integer)
  k <= length(L.colstops) && L.colstops[k] != -1 && return L.colstops[k]
  transfer_getindex(L,(1,1,ApproxFun.∞),k:k)
  L.colstops[k]
end

function ApproxFun.resizedata!{T,D<:Domain,R<:Domain,M<:AbstractMarkovMap}(co::ApproxFun.CachedOperator{T,ApproxFun.RaggedMatrix{T},ConcreteTransfer{T,D,R,M}},::Colon,n::Integer)
  if n > co.datasize[2]
    RO = transfer_getindex(co.op,(1,1,ApproxFun.∞),(co.datasize[2]+1):n,padding)
    if co.datasize[2] == 0
      co.data = RO
      co.datasize = (co.data.K,n)
    else
      append!(co.data.data,RO.data)
      append!(co.data.cols,RO.cols[2:end]+co.data.cols[end])
      co.data.K = max(co.data.K,RO.K)
      co.datasize = (co.data.K,n)
    end
  end

  co
end