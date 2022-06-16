using Pkg
Pkg.develop(PackageSpec(path="/home/shugo/packages/CCBlade.jl"))   # developer install of the local package.
Pkg.add("ConcreteStructs")
Pkg.add("ForwardDiff")
# OpenMDAO.jl isn't a Registered Julia Package®™©, so need to specify the url.
Pkg.add(PackageSpec(url="https://github.com/byuflowlab/OpenMDAO.jl"))
Pkg.add("PyCall")
Pkg.build("PyCall")
using CCBlade
using ConcreteStructs
using ForwardDiff
using OpenMDAO
using PyCall
