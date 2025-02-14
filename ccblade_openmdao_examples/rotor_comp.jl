# rotor component with non-perpendicular inflow, i.e., considers parallel-to-disk flow component.
# Basically a copy of component_analysis.jl, but I added the azimuth discretization. I also removed figure_of_merit

# task for 5/11
# TODO: clean and remove unnecessary comments

@concrete struct BEMTRotorCACompSideFlow <: AbstractImplicitComp
    num_operating_points
    num_blades
    num_radial
    num_azimuth  # azimuth discretization for parallel-to-disk flow component
    rho
    mu
    speedofsound
    airfoil_interp
    mach
    reynolds
    rotation
    tip
    apply_nonlinear_forwarddiffable!
    x
    y
    J
    forwarddiff_config
end

function BEMTRotorCACompSideFlow(; af_fname, cr75, Re_exp, num_operating_points, num_blades, num_radial, num_azimuth, rho, mu, speedofsound, use_hubtip_losses=true)
    # Get the airfoil polar interpolator and various correction factors.
    if typeof(af_fname) == String
        # input: one xfoil data.
        print("...loading xfoil data ")
        println(af_fname)
        af, mach, reynolds, rotation, tip = get_airfoil(af_fname=af_fname, cr75=cr75, Re_exp=Re_exp)   
    else
        # input: multiple xfoil data at various Reynolds number
        af, mach, reynolds, rotation, tip = get_airfoil_Re_data(af_fnames=af_fname, cr75=cr75)
    end

    if ! use_hubtip_losses
        tip = nothing
    end

    # print corrections
    println("--- airfoil corrections ---")
    print("Mach: ")
    print(mach)
    print(", Reynolds: ")
    print(reynolds)
    print(", Rotation: ")
    print(rotation)
    print(", Tip: ")
    println(tip)

    function apply_nonlinear_forwarddiffable!(y, x)
        T = eltype(x)

        # Azimuth discretization
        azangles_aug = range(0, 2 * pi, length=num_azimuth + 1)
        azangles = azangles_aug[1:num_azimuth]  # remove the last point (360 deg)

        # Unpack the inputs.
        phi = x[:phi]
        Rhub = x[:Rhub]
        Rtip = x[:Rtip]
        radii = x[:radii]
        chord = x[:chord]
        theta = x[:theta]
        v = x[:v]
        v_pal = x[:v_pal]
        omega = x[:omega]
        pitch = x[:pitch]

        # Create the CCBlade rotor struct.
        turbine = false
        precone = zero(T)
        rotor = CCBlade.Rotor(Rhub, Rtip, num_blades, precone, turbine, mach, reynolds, rotation, tip)

        # Create the CCBlade sections.
        sections = CCBlade.Section.(radii, chord, theta, Ref(af))

        # Create the CCBlade operating points.
        Vx = v
        Vrot = omega.*radii   # rotational velocity, length=num_radial
        Vs = v_pal * sin.(azangles)   # side flow velocity, length=num_azimuth
        Vy = Vrot .+ Vs'   # 2D matrix, (num_radial, num_azimuth)
        ops = CCBlade.OperatingPoint.(Vx, Vy, rho, pitch, mu, speedofsound)

        # Solve the BEMT equations.
        Rs_and_outs = CCBlade.residual.(phi, Ref(rotor), sections, ops)
        Rs = getindex.(Rs_and_outs, 1)
        outs = getindex.(Rs_and_outs, 2)

        # Get the thrust and torque, then the efficiency, etc.
        # coefficients.
        thrust, torque, drag = CCBlade.thrusttorquedrag(rotor, sections, azangles, outs)
        # NOTE: "drag" is the in-plane force in skewed-flow direction, thus "drag" of the rotor as an lifting surface.
        eff, CT, CQ = CCBlade.nondim(thrust, torque, Vx, omega, rho, rotor, "propeller")
        ### if thrust > zero(T)
        ###     figure_of_merit, CT, CP = CCBlade.nondim(thrust, torque, Vx, omega, rho, rotor, "helicopter")
        ### else
        ###     figure_of_merit = zero(T)
        ### end

        # Put the outputs in the output array.
        y[:phi] .= Rs
        y[:thrust] = thrust
        y[:drag] = drag
        y[:torque] = torque
        y[:eff] = eff
        ### y[:figure_of_merit] = figure_of_merit
        return nothing
    end

    # Initialize the input and output vectors needed by ForwardDiff.jl. (The
    # ForwardDiff.jl inputs include phi, but that's an OpenMDAO output.)
    X = ComponentArray(
        phi=zeros(Float64, (num_radial, num_azimuth)), Rhub=0.0, Rtip=0.0, radii=zeros(Float64, num_radial), chord=zeros(Float64, num_radial),
        theta=zeros(Float64, num_radial), v=0.0, v_pal=0.0, omega=0.0, pitch=0.0)
    Y = ComponentArray(
        phi=zeros(Float64, (num_radial, num_azimuth)), thrust=0.0, drag=0.0, torque=0.0, eff=0.0)   # to compute figure_of_merit, must add it here.
    J = Y.*X'

    # Get the JacobianConfig object, which we'll reuse each time when calling
    # the ForwardDiff.jacobian! function (apparently good for efficiency).
    config = ForwardDiff.JacobianConfig(apply_nonlinear_forwarddiffable!, Y, X)

    return BEMTRotorCACompSideFlow(num_operating_points, num_blades, num_radial, num_azimuth, rho, mu, speedofsound, af, mach, reynolds, rotation, tip, apply_nonlinear_forwarddiffable!, X, Y, J, config)
end

#' Need a setup function, just like a Python OpenMDAO `Component`.
function OpenMDAO.setup(self::BEMTRotorCACompSideFlow)
    num_operating_points = self.num_operating_points
    num_radial = self.num_radial
    num_azimuth = self.num_azimuth

    # Declare the OpenMDAO inputs.
    input_data = Vector{VarData}()
    push!(input_data, VarData("Rhub", shape=1, val=0.1, units="m"))
    push!(input_data, VarData("Rtip", shape=1, val=2.0, units="m"))
    push!(input_data, VarData("radii", shape=num_radial, val=1., units="m"))
    push!(input_data, VarData("chord", shape=num_radial, val=1., units="m"))
    push!(input_data, VarData("theta", shape=num_radial, val=1., units="rad"))
    push!(input_data, VarData("v", shape=num_operating_points, val=1., units="m/s"))   # normal to disk
    push!(input_data, VarData("v_pal", shape=num_operating_points, val=0., units="m/s"))   # parallel to disk
    push!(input_data, VarData("omega", shape=num_operating_points, val=1., units="rad/s"))
    push!(input_data, VarData("pitch", shape=num_operating_points, val=0., units="rad"))

    # Declare the OpenMDAO outputs.
    output_data = Vector{VarData}()
    push!(output_data, VarData("phi", shape=(num_operating_points, num_radial, num_azimuth), val=1.0, units="rad"))   # [i, j, l]
    push!(output_data, VarData("thrust", shape=num_operating_points, val=1.0, units="N"))
    push!(output_data, VarData("drag", shape=num_operating_points, val=0.0, units="N"))
    push!(output_data, VarData("torque", shape=num_operating_points, val=1.0, units="N*m"))
    push!(output_data, VarData("efficiency", shape=num_operating_points, val=1.0))
    ### push!(output_data, VarData("figure_of_merit", shape=num_operating_points, val=1.0))

    # Declare the OpenMDAO partial derivatives.
    ss_sizes = Dict(:i=>num_operating_points, :j=>num_radial, :k=>1, :l=>num_azimuth)
    partials_data = Vector{PartialsData}()

    rows, cols = get_rows_cols(ss_sizes=ss_sizes, of_ss=[:i, :j, :l], wrt_ss=[:k])
    push!(partials_data, PartialsData("phi", "Rhub", rows=rows, cols=cols))
    push!(partials_data, PartialsData("phi", "Rtip", rows=rows, cols=cols))

    rows, cols = get_rows_cols(ss_sizes=ss_sizes, of_ss=[:i, :j, :l], wrt_ss=[:j])
    push!(partials_data, PartialsData("phi", "radii", rows=rows, cols=cols))
    push!(partials_data, PartialsData("phi", "chord", rows=rows, cols=cols))
    push!(partials_data, PartialsData("phi", "theta", rows=rows, cols=cols))

    rows, cols = get_rows_cols(ss_sizes=ss_sizes, of_ss=[:i, :j, :l], wrt_ss=[:i])
    push!(partials_data, PartialsData("phi", "v", rows=rows, cols=cols))
    push!(partials_data, PartialsData("phi", "v_pal", rows=rows, cols=cols))
    push!(partials_data, PartialsData("phi", "omega", rows=rows, cols=cols))
    push!(partials_data, PartialsData("phi", "pitch", rows=rows, cols=cols))

    rows, cols = get_rows_cols(ss_sizes=ss_sizes, of_ss=[:i, :j, :l], wrt_ss=[:i, :j, :l])
    push!(partials_data, PartialsData("phi", "phi", rows=rows, cols=cols))

    rows, cols = get_rows_cols(ss_sizes=ss_sizes, of_ss=[:i], wrt_ss=[:k])
    push!(partials_data, PartialsData("thrust", "Rhub", rows=rows, cols=cols))
    push!(partials_data, PartialsData("thrust", "Rtip", rows=rows, cols=cols))
    push!(partials_data, PartialsData("drag", "Rhub", rows=rows, cols=cols))
    push!(partials_data, PartialsData("drag", "Rtip", rows=rows, cols=cols))
    push!(partials_data, PartialsData("torque", "Rhub", rows=rows, cols=cols))
    push!(partials_data, PartialsData("torque", "Rtip", rows=rows, cols=cols))
    push!(partials_data, PartialsData("efficiency", "Rhub", rows=rows, cols=cols))
    push!(partials_data, PartialsData("efficiency", "Rtip", rows=rows, cols=cols))
    ### push!(partials_data, PartialsData("figure_of_merit", "Rhub", rows=rows, cols=cols))
    ### push!(partials_data, PartialsData("figure_of_merit", "Rtip", rows=rows, cols=cols))

    rows, cols = get_rows_cols(ss_sizes=ss_sizes, of_ss=[:i], wrt_ss=[:j])
    push!(partials_data, PartialsData("thrust", "radii", rows=rows, cols=cols))
    push!(partials_data, PartialsData("thrust", "chord", rows=rows, cols=cols))
    push!(partials_data, PartialsData("thrust", "theta", rows=rows, cols=cols))
    push!(partials_data, PartialsData("drag", "radii", rows=rows, cols=cols))
    push!(partials_data, PartialsData("drag", "chord", rows=rows, cols=cols))
    push!(partials_data, PartialsData("drag", "theta", rows=rows, cols=cols))
    push!(partials_data, PartialsData("torque", "radii", rows=rows, cols=cols))
    push!(partials_data, PartialsData("torque", "chord", rows=rows, cols=cols))
    push!(partials_data, PartialsData("torque", "theta", rows=rows, cols=cols))
    push!(partials_data, PartialsData("efficiency", "radii", rows=rows, cols=cols))
    push!(partials_data, PartialsData("efficiency", "chord", rows=rows, cols=cols))
    push!(partials_data, PartialsData("efficiency", "theta", rows=rows, cols=cols))
    ### push!(partials_data, PartialsData("figure_of_merit", "radii", rows=rows, cols=cols))
    ### push!(partials_data, PartialsData("figure_of_merit", "chord", rows=rows, cols=cols))
    ### push!(partials_data, PartialsData("figure_of_merit", "theta", rows=rows, cols=cols))

    rows, cols = get_rows_cols(ss_sizes=ss_sizes, of_ss=[:i], wrt_ss=[:i])
    push!(partials_data, PartialsData("thrust", "v", rows=rows, cols=cols))
    push!(partials_data, PartialsData("thrust", "v_pal", rows=rows, cols=cols))
    push!(partials_data, PartialsData("thrust", "omega", rows=rows, cols=cols))
    push!(partials_data, PartialsData("thrust", "pitch", rows=rows, cols=cols))
    push!(partials_data, PartialsData("thrust", "thrust", rows=rows, cols=cols, val=-1.0))
    push!(partials_data, PartialsData("drag", "v", rows=rows, cols=cols))
    push!(partials_data, PartialsData("drag", "v_pal", rows=rows, cols=cols))
    push!(partials_data, PartialsData("drag", "omega", rows=rows, cols=cols))
    push!(partials_data, PartialsData("drag", "pitch", rows=rows, cols=cols))
    push!(partials_data, PartialsData("drag", "drag", rows=rows, cols=cols, val=-1.0))
    push!(partials_data, PartialsData("torque", "v", rows=rows, cols=cols))
    push!(partials_data, PartialsData("torque", "v_pal", rows=rows, cols=cols))
    push!(partials_data, PartialsData("torque", "omega", rows=rows, cols=cols))
    push!(partials_data, PartialsData("torque", "pitch", rows=rows, cols=cols))
    push!(partials_data, PartialsData("torque", "torque", rows=rows, cols=cols, val=-1.0))
    push!(partials_data, PartialsData("efficiency", "v", rows=rows, cols=cols))
    push!(partials_data, PartialsData("efficiency", "v_pal", rows=rows, cols=cols))
    push!(partials_data, PartialsData("efficiency", "omega", rows=rows, cols=cols))
    push!(partials_data, PartialsData("efficiency", "pitch", rows=rows, cols=cols))
    push!(partials_data, PartialsData("efficiency", "efficiency", rows=rows, cols=cols, val=-1.0))
    ### push!(partials_data, PartialsData("figure_of_merit", "v", rows=rows, cols=cols))
    ### push!(partials_data, PartialsData("figure_of_merit", "v_pal", rows=rows, cols=cols))
    ### push!(partials_data, PartialsData("figure_of_merit", "omega", rows=rows, cols=cols))
    ### push!(partials_data, PartialsData("figure_of_merit", "pitch", rows=rows, cols=cols))
    ### push!(partials_data, PartialsData("figure_of_merit", "figure_of_merit", rows=rows, cols=cols, val=-1.0))

    rows, cols = get_rows_cols(ss_sizes=ss_sizes, of_ss=[:i], wrt_ss=[:i, :j, :l])
    push!(partials_data, PartialsData("thrust", "phi", rows=rows, cols=cols))
    push!(partials_data, PartialsData("drag", "phi", rows=rows, cols=cols))
    push!(partials_data, PartialsData("torque", "phi", rows=rows, cols=cols))
    push!(partials_data, PartialsData("efficiency", "phi", rows=rows, cols=cols))
    ### push!(partials_data, PartialsData("figure_of_merit", "phi", rows=rows, cols=cols))

    return input_data, output_data, partials_data
end

# We'll define a `solve_nonlinear` function, since CCBlade.jl knows how to
# converge it's own residual.
function OpenMDAO.solve_nonlinear!(self::BEMTRotorCACompSideFlow, inputs, outputs)
    # Unpack all the options.
    num_operating_points = self.num_operating_points
    num_blades = self.num_blades
    num_radial = self.num_radial
    rho = self.rho
    mu = self.mu
    speedofsound = self.speedofsound
    af = self.airfoil_interp
    mach = self.mach
    reynolds = self.reynolds
    rotation = self.rotation
    tip = self.tip

    num_azimuth = self.num_azimuth   # number of azimuth discretization.

    # Unpack the inputs.
    Rhub = inputs["Rhub"][1]
    Rtip = inputs["Rtip"][1]
    radii = inputs["radii"]
    chord = inputs["chord"]
    theta = inputs["theta"]
    v = inputs["v"]
    v_pal = inputs["v_pal"]
    omega = inputs["omega"]
    pitch = inputs["pitch"]

    # Unpack the outputs.
    phi = outputs["phi"]
    thrust = outputs["thrust"]
    drag = outputs["drag"]
    torque = outputs["torque"]
    efficiency = outputs["efficiency"]
    ### figure_of_merit = outputs["figure_of_merit"]

    # Create the CCBlade rotor struct. Same for each operating point and radial
    # element.
    T = typeof(Rhub)
    precone = zero(T)
    turbine = false
    rotor = CCBlade.Rotor(Rhub, Rtip, num_blades, precone, turbine, mach, reynolds, rotation, tip)

    # Create the CCBlade sections.
    sections = CCBlade.Section.(radii, chord, theta, Ref(af))

    # Azimuth discretization. If num_azimuth=1, then the effect of sideflow (sin(azimuth)) is 0.
    azangles_aug = range(0, 2 * pi, length=num_azimuth + 1)
    azangles = azangles_aug[1:num_azimuth]  # remove the last point (360 deg)

    for n in 1:num_operating_points
        # Create the CCBlade operating points.
        Vx = v[n]
        Vrot = omega[n].*radii   # rotational velocity, length=num_radial
        Vs = v_pal[n] * sin.(azangles)   # side flow velocity, length=num_azimuth
        Vy = Vrot .+ Vs'   # 2D matrix, (num_radial, num_azimuth)
        ops = CCBlade.OperatingPoint.(Vx, Vy, rho, pitch[n], mu, speedofsound)

        # Solve the BEMT equation.
        outs = CCBlade.solve.(Ref(rotor), sections, ops)

        # Get the thrust, torque, and efficiency.
        thrust[n], torque[n], drag[n] = CCBlade.thrusttorquedrag(rotor, sections, azangles, outs)
        efficiency[n], CT, CQ = CCBlade.nondim(thrust[n], torque[n], Vx, omega[n], rho, rotor, "propeller")
        ### if thrust[n] > zero(T)
        ###     figure_of_merit[n], CT, CP = CCBlade.nondim(thrust[n], torque[n], Vx, omega[n], rho, rotor, "helicopter")
        ### else
        ###     figure_of_merit[n] = zero(T)
        ### end

        # Get the local inflow angle, the BEMT implicit variable.
        phi[n, :, :] .= getproperty.(outs, :phi)
    end

    return nothing
end

#' Since we have a `solve_nonlinear` function, I don't think we necessarily need
#' an `apply_nonlinear` since CCBlade will converge the BEMT equation, not
#' OpenMDAO. But I think the `apply_nonlinear` will be handy for checking the
#' the partial derivatives of the `BEMTRotorCAComp` `Component`.
#+ results="hidden"
function OpenMDAO.apply_nonlinear!(self::BEMTRotorCACompSideFlow, inputs, outputs, residuals)
    # Unpack all the options.
    num_operating_points = self.num_operating_points
    num_blades = self.num_blades
    num_radial = self.num_radial
    num_azimuth = self.num_azimuth
    rho = self.rho
    mu = self.mu
    speedofsound = self.speedofsound
    af = self.airfoil_interp
    mach = self.mach
    reynolds = self.reynolds
    rotation = self.rotation
    tip = self.tip

    # Unpack the inputs.
    Rhub = inputs["Rhub"][1]
    Rtip = inputs["Rtip"][1]
    radii = inputs["radii"]
    chord = inputs["chord"]
    theta = inputs["theta"]
    v = inputs["v"]
    v_pal = inputs["v_pal"]
    omega = inputs["omega"]
    pitch = inputs["pitch"]

    # Create the CCBlade rotor struct. Same for each operating point and radial
    # element.
    T = typeof(Rhub)
    precone = zero(T)
    turbine = false
    rotor = CCBlade.Rotor(Rhub, Rtip, num_blades, precone, turbine, mach, reynolds, rotation, tip)

    # Create the CCBlade sections.
    sections = CCBlade.Section.(radii, chord, theta, Ref(af))

    # Azimuth discretization
    azangles_aug = range(0, 2 * pi, length=num_azimuth + 1)
    azangles = azangles_aug[1:num_azimuth]  # remove the last point (360 deg)

    # outs = Vector{CCBlade.Outputs{T}}(undef, num_radial)
    for n in 1:num_operating_points
        # Create the CCBlade operating points.
        Vx = v[n]
        Vrot = omega[n].*radii   # rotational velocity, length=num_radial
        Vs = v_pal[n] * sin.(azangles)   # side flow velocity, length=num_azimuth.
        Vy = Vrot .+ Vs'   # 2D matrix, (num_radial, num_azimuth)
        ops = CCBlade.OperatingPoint.(Vx, Vy, rho, pitch[n], mu, speedofsound)

        # Get the residual of the BEMT equation. This should return a Vector of
        # length num_radial with each entry being a 2-length Tuple. First entry
        # in the Tuple is the residual (`Float64`), second is the CCBlade
        # `Output` struct`.
        # Actually this now returns a matrix (num_radial, num_azimuth)
        Rs_and_outs = CCBlade.residual.(outputs["phi"][n, :, :], Ref(rotor), sections, ops)

        # Set the phi residual.
        residuals["phi"][n, :, :] .= getindex.(Rs_and_outs, 1)

        # Get the thrust, torque, and efficiency.
        outs = getindex.(Rs_and_outs, 2)

        thrust, torque, drag = CCBlade.thrusttorquedrag(rotor, sections, azangles, outs)
        efficiency, CT, CQ = CCBlade.nondim(thrust, torque, Vx, omega[n], rho, rotor, "propeller")
        ### if thrust > zero(T)
        ###     figure_of_merit, CT, CP = CCBlade.nondim(thrust, torque, Vx, omega[n], rho, rotor, "helicopter")
        ### else
        ###     figure_of_merit = zero(T)
        ### end

        # Set the residuals of the thrust, torque, and efficiency.
        residuals["thrust"][n] = thrust - outputs["thrust"][n]
        residuals["drag"][n] = drag - outputs["drag"][n]
        residuals["torque"][n] = torque - outputs["torque"][n]
        residuals["efficiency"][n] = efficiency - outputs["efficiency"][n]
        ### residuals["figure_of_merit"][n] = figure_of_merit - outputs["figure_of_merit"][n]
    end

end

# Now for the big one: the `linearize!` function will calculate the derivatives
# of the BEMT component residuals wrt the inputs and outputs. We'll use the
# Julia package ForwardDiff.jl to actually calculate the derivatives.
function OpenMDAO.linearize!(self::BEMTRotorCACompSideFlow, inputs, outputs, partials)
    # Unpack the options we'll need.
    num_operating_points = self.num_operating_points
    num_radial = self.num_radial
    num_azimuth = self.num_azimuth

    # Unpack the inputs.
    Rhub = inputs["Rhub"][1]
    Rtip = inputs["Rtip"][1]
    radii = inputs["radii"]
    chord = inputs["chord"]
    theta = inputs["theta"]
    v = inputs["v"]
    v_pal = inputs["v_pal"]
    omega = inputs["omega"]
    pitch = inputs["pitch"]

    # Azimuth discretization
    azangles_aug = range(0, 2 * pi, length=num_azimuth + 1)
    azangles = azangles_aug[1:num_azimuth]  # remove the last point (360 deg)

    # Unpack the output.
    phi = outputs["phi"]

    # Working arrays and configuration for ForwardDiff's Jacobian routine.
    x = self.x
    y = self.y
    J = self.J
    config = self.forwarddiff_config
    
    # These need to be transposed because of the differences in array layout
    # between NumPy and Julia. When I declare the partials above, they get set up
    # on the OpenMDAO side in a shape=(num_operating_points, num_radial), and
    # are then flattened. That gets passed to Julia. Since Julia uses column
    # major arrays, we have to reshape the array with the indices reversed, then
    # transpose them.
    #=
    e.g., A = 
    1 3 5 7
    2 4 6 8

    Then, transpose(reshape(A, 4, 2)) =
    1 2 3 4
    5 6 7 8
    =#

    # Note: PermutedDimsArray is similar to permutedims, but it does not copy, like the transpose does not.
    dphi_dRhub = PermutedDimsArray(reshape(partials["phi", "Rhub"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    dphi_dRtip = PermutedDimsArray(reshape(partials["phi", "Rtip"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    dphi_dradii = PermutedDimsArray(reshape(partials["phi", "radii"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    dphi_dchord = PermutedDimsArray(reshape(partials["phi", "chord"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    dphi_dtheta = PermutedDimsArray(reshape(partials["phi", "theta"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    dphi_dv = PermutedDimsArray(reshape(partials["phi", "v"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    dphi_dv_pal = PermutedDimsArray(reshape(partials["phi", "v_pal"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    dphi_domega = PermutedDimsArray(reshape(partials["phi", "omega"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    dphi_dpitch = PermutedDimsArray(reshape(partials["phi", "pitch"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    dphi_dphi = PermutedDimsArray(reshape(partials["phi", "phi"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    

    dthrust_dRhub = partials["thrust", "Rhub"]
    dthrust_dRtip = partials["thrust", "Rtip"]
    ddrag_dRhub = partials["drag", "Rhub"]
    ddrag_dRtip = partials["drag", "Rtip"]
    dtorque_dRhub = partials["torque", "Rhub"]
    dtorque_dRtip = partials["torque", "Rtip"]
    defficiency_dRhub = partials["efficiency", "Rhub"]
    defficiency_dRtip = partials["efficiency", "Rtip"]
    ### dfigure_of_merit_dRhub = partials["figure_of_merit", "Rhub"]
    ### dfigure_of_merit_dRtip = partials["figure_of_merit", "Rtip"]

    dthrust_dradii = transpose(reshape(partials["thrust", "radii"], num_radial, num_operating_points))
    dthrust_dchord = transpose(reshape(partials["thrust", "chord"], num_radial, num_operating_points))
    dthrust_dtheta = transpose(reshape(partials["thrust", "theta"], num_radial, num_operating_points))
    ddrag_dradii = transpose(reshape(partials["drag", "radii"], num_radial, num_operating_points))
    ddrag_dchord = transpose(reshape(partials["drag", "chord"], num_radial, num_operating_points))
    ddrag_dtheta = transpose(reshape(partials["drag", "theta"], num_radial, num_operating_points))
    dtorque_dradii = transpose(reshape(partials["torque", "radii"], num_radial, num_operating_points))
    dtorque_dchord = transpose(reshape(partials["torque", "chord"], num_radial, num_operating_points))
    dtorque_dtheta = transpose(reshape(partials["torque", "theta"], num_radial, num_operating_points))
    defficiency_dradii = transpose(reshape(partials["efficiency", "radii"], num_radial, num_operating_points))
    defficiency_dchord = transpose(reshape(partials["efficiency", "chord"], num_radial, num_operating_points))
    defficiency_dtheta = transpose(reshape(partials["efficiency", "theta"], num_radial, num_operating_points))
    ### dfigure_of_merit_dradii = transpose(reshape(partials["figure_of_merit", "radii"], num_radial, num_operating_points))
    ### dfigure_of_merit_dchord = transpose(reshape(partials["figure_of_merit", "chord"], num_radial, num_operating_points))
    ### dfigure_of_merit_dtheta = transpose(reshape(partials["figure_of_merit", "theta"], num_radial, num_operating_points))

    dthrust_dv = partials["thrust", "v"]
    dthrust_dv_pal = partials["thrust", "v_pal"]
    dthrust_domega = partials["thrust", "omega"]
    dthrust_dpitch = partials["thrust", "pitch"]
    ddrag_dv = partials["drag", "v"]
    ddrag_dv_pal = partials["drag", "v_pal"]
    ddrag_domega = partials["drag", "omega"]
    ddrag_dpitch = partials["drag", "pitch"]
    dtorque_dv = partials["torque", "v"]
    dtorque_dv_pal = partials["torque", "v_pal"]
    dtorque_domega = partials["torque", "omega"]
    dtorque_dpitch = partials["torque", "pitch"]
    defficiency_dv = partials["efficiency", "v"]
    defficiency_dv_pal = partials["efficiency", "v_pal"]
    defficiency_domega = partials["efficiency", "omega"]
    defficiency_dpitch = partials["efficiency", "pitch"]
    ### dfigure_of_merit_dv = partials["figure_of_merit", "v"]
    ### dfigure_of_merit_domega = partials["figure_of_merit", "omega"]
    ### dfigure_of_merit_dpitch = partials["figure_of_merit", "pitch"]

    
    dthrust_dphi = PermutedDimsArray(reshape(partials["thrust", "phi"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    ddrag_dphi = PermutedDimsArray(reshape(partials["drag", "phi"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    dtorque_dphi = PermutedDimsArray(reshape(partials["torque", "phi"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    defficiency_dphi = PermutedDimsArray(reshape(partials["efficiency", "phi"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))
    ### dfigure_of_merit_dphi = PermutedDimsArray(reshape(partials["figure_of_merit", "phi"], num_azimuth, num_radial, num_operating_points), (3, 2, 1))

    for n in 1:num_operating_points
        # Put the inputs into the input array for ForwardDiff.
        x[:phi] .= phi[n, :, :]
        x[:Rhub] = Rhub
        x[:Rtip] = Rtip
        x[:radii] .= radii
        x[:chord] .= chord
        x[:theta] .= theta
        x[:v] = v[n]
        x[:v_pal] = v_pal[n]
        x[:omega] = omega[n]
        x[:pitch] = pitch[n]

        # Get the Jacobian.
        ForwardDiff.jacobian!(J, self.apply_nonlinear_forwarddiffable!, y, x, config)
        # TODO-FFR: check config file for better performance?

        dphi_dRhub[n, :, :] .= J[:phi, :Rhub]
        dphi_dRtip[n, :, :] .= J[:phi, :Rtip]

        # TODO: vectorize to accelerate?
        count = 1
        for k in 1:num_azimuth
            for r in 1:num_radial
                # for some reason, J[:phi, :radii] does not work...
                ### dphi_dradii[n, r, k] = J[:phi, :radii][r, k, r]
                ### dphi_dchord[n, r, k] = J[:phi, :chord][r, k, r]
                ### dphi_dtheta[n, r, k] = J[:phi, :theta][r, k, r]
                # thus instead, need to hardcode the indices slice for :phi. Order of loop (k and r) corresponds to the flattening.
                dphi_dradii[n, r, k] = J[1:num_radial*num_azimuth, :radii][count, r]
                dphi_dchord[n, r, k] = J[1:num_radial*num_azimuth, :chord][count, r]
                dphi_dtheta[n, r, k] = J[1:num_radial*num_azimuth, :theta][count, r]
                dphi_dphi[n, r, k] = J[:phi, :phi][r, k, r, k]
                count = count + 1
            end
        end

        dphi_dv[n, :, :] .= J[:phi, :v]
        dphi_dv_pal[n, :, :] .= J[:phi, :v_pal]
        dphi_domega[n, :, :] .= J[:phi, :omega]
        dphi_dpitch[n, :, :] .= J[:phi, :pitch]

        dthrust_dphi[n, :, :] .= J[:thrust, :phi]
        dthrust_dRhub[n] = J[:thrust, :Rhub]
        dthrust_dRtip[n] = J[:thrust, :Rtip]
        dthrust_dradii[n, :] .= J[:thrust, :radii]
        dthrust_dchord[n, :] .= J[:thrust, :chord]
        dthrust_dtheta[n, :] .= J[:thrust, :theta]
        dthrust_dv[n] = J[:thrust, :v]
        dthrust_dv_pal[n] = J[:thrust, :v_pal]
        dthrust_domega[n] = J[:thrust, :omega]
        dthrust_dpitch[n] = J[:thrust, :pitch]

        ddrag_dphi[n, :, :] .= J[:drag, :phi]
        ddrag_dRhub[n] = J[:drag, :Rhub]
        ddrag_dRtip[n] = J[:drag, :Rtip]
        ddrag_dradii[n, :] .= J[:drag, :radii]
        ddrag_dchord[n, :] .= J[:drag, :chord]
        ddrag_dtheta[n, :] .= J[:drag, :theta]
        ddrag_dv[n] = J[:drag, :v]
        ddrag_dv_pal[n] = J[:drag, :v_pal]
        ddrag_domega[n] = J[:drag, :omega]
        ddrag_dpitch[n] = J[:drag, :pitch]

        dtorque_dphi[n, :, :] .= J[:torque, :phi]
        dtorque_dRhub[n] = J[:torque, :Rhub]
        dtorque_dRtip[n] = J[:torque, :Rtip]
        dtorque_dradii[n, :] .= J[:torque, :radii]
        dtorque_dchord[n, :] .= J[:torque, :chord]
        dtorque_dtheta[n, :] .= J[:torque, :theta]
        dtorque_dv[n] = J[:torque, :v]
        dtorque_dv_pal[n] = J[:torque, :v_pal]
        dtorque_domega[n] = J[:torque, :omega]
        dtorque_dpitch[n] = J[:torque, :pitch]

        defficiency_dphi[n, :, :] .= J[:eff, :phi]
        defficiency_dRhub[n] = J[:eff, :Rhub]
        defficiency_dRtip[n] = J[:eff, :Rtip]
        defficiency_dradii[n, :] .= J[:eff, :radii]
        defficiency_dchord[n, :] .= J[:eff, :chord]
        defficiency_dtheta[n, :] .= J[:eff, :theta]
        defficiency_dv[n] = J[:eff, :v]
        defficiency_dv_pal[n] = J[:eff, :v_pal]
        defficiency_domega[n] = J[:eff, :omega]
        defficiency_dpitch[n] = J[:eff, :pitch]

        #=
        dfigure_of_merit_dphi[n, :, :] .= J[:figure_of_merit, :phi]
        dfigure_of_merit_dRhub[n] = J[:figure_of_merit, :Rhub]
        dfigure_of_merit_dRtip[n] = J[:figure_of_merit, :Rtip]
        dfigure_of_merit_dradii[n, :] .= J[:figure_of_merit, :radii]
        dfigure_of_merit_dchord[n, :] .= J[:figure_of_merit, :chord]
        dfigure_of_merit_dtheta[n, :] .= J[:figure_of_merit, :theta]
        dfigure_of_merit_dv[n] = J[:figure_of_merit, :v]
        dfigure_of_merit_domega[n] = J[:figure_of_merit, :omega]
        dfigure_of_merit_dpitch[n] = J[:figure_of_merit, :pitch]
        =#
    end

    return nothing
end

# Disable checking for guess_nonlinear and apply_nonlinear functions.
OpenMDAO.detect_guess_nonlinear(::Type{<:BEMTRotorCACompSideFlow}) = false
OpenMDAO.detect_apply_linear(::Type{<:BEMTRotorCACompSideFlow}) = false
