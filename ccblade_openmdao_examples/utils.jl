function get_airfoil(; af_fname, cr75, Re_exp)
    # input: one xfoil data at certain Reynolds number
    # then, enable Reynolds, Mach, and rotational corrections

    (info, Re, Mach, alpha, cl, cd) = CCBlade.parsefile(af_fname, false)

    # Extend the angle of attack with the Viterna method.
    (alpha, cl, cd) = CCBlade.viterna(alpha, cl, cd, cr75)
    af = CCBlade.AlphaAF(alpha, cl, cd, info, Re, Mach)

    # Reynolds number correction. The 0.6 factor seems to match the NACA 0012
    # drag data from airfoiltools.com.
    reynolds = CCBlade.SkinFriction(Re, Re_exp)  # this correction is probably not accurate for high angle-of-attack
    ### reynolds = nothing

    # Mach number correction.
    ### mach = CCBlade.PrandtlGlauert()
    mach = nothing

    # Rotational stall delay correction. Need some parameters from the CL curve.
    m, alpha0 = CCBlade.linearliftcoeff(af, 1.0, 1.0)  # dummy values for Re and Mach
    # Create the Du Selig and Eggers correction.
    rotation = CCBlade.DuSeligEggers(1.0, 1.0, 1.0, m, alpha0)

    # The usual hub and tip loss correction.
    tip = CCBlade.PrandtlTipHub()

    return af, mach, reynolds, rotation, tip
end


function get_airfoil_Re_data(; af_fnames, cr75)
    # af_fnames: list of xfoil data. Then it will create 2D interpolation in alpha-Re space.
    # Re_exp does nothing, but just keep this.
    # This is more accurate than on-the-fly Reynolds correction, but also quite expensive.

    # NOTE: this is extremely slow !!

    # --- prepare airfoil interpolation ---
    num_Re = length(af_fnames)

    # prepare data array
    alpha_all = Vector(range(-pi, pi, length=200))
    Re_all = zeros(num_Re + 2)
    cl_all = zeros(200, num_Re + 2)   # Repeat the data for min and max Reynolds number for "extrapolation"
    cd_all = zeros(200, num_Re + 2)

    for i in 1:num_Re
        # load data
        ### print("loading ")
        ### println(xfoil_filenames[i])
        (info, Re, Mach, alpha, cl, cd) = CCBlade.parsefile(af_fnames[i], false)   # set "false" to convert alpha into radians
        # Viterna extrapolation
        (alpha, cl, cd) = CCBlade.viterna(alpha, cl, cd, cr75)
        # get data at alpha_all by 1D linear interpolation
        cl = FLOWMath.linear(alpha, cl, alpha_all)
        cd = FLOWMath.linear(alpha, cd, alpha_all)
        
        Re_all[i + 1] = Re
        cl_all[:, i + 1] = cl
        cd_all[:, i + 1] = cd
    end

    # add dummy duplicate data at both end for "extrapolation"
    Re_all[1] = 1.0
    cl_all[:, 1] = cl_all[:, 2] * 0.99
    cd_all[:, 1] = cd_all[:, 2] * 0.99

    Re_all[num_Re + 2] = Re_all[num_Re + 1] * 1000
    cl_all[:, num_Re + 2] = cl_all[:, num_Re + 1] * 1.01
    cd_all[:, num_Re + 2] = cd_all[:, num_Re + 1] * 1.01

    ### Re_all = [1.0, 50000.0, 100000.0, 200000.0, 500000.0, 1000000.0, 100000000.0]   # overwrite for debug !
    print("...loading xfoil data at Re = ")
    println(Re_all')

    # airfoil 2D interpolation
    af = CCBlade.AlphaReAF(alpha_all, Re_all, cl_all, cd_all)

    # --- corrections ---
    reynolds = nothing   # we already did this in using the xfoil data
    mach = nothing

    # Rotational stall delay correction. Need some parameters from the CL curve.
    m, alpha0 = CCBlade.linearliftcoeff(af, 1.0, 1.0)  # dummy values for Re and Mach
    # Create the Du Selig and Eggers correction.
    rotation = CCBlade.DuSeligEggers(1.0, 1.0, 1.0, m, alpha0)

    # The usual hub and tip loss correction.
    tip = CCBlade.PrandtlTipHub()

    return af, mach, reynolds, rotation, tip
end