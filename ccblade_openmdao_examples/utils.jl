function get_airfoil(; af_fname, cr75, Re_exp)
    # input: one xfoil data at certain Reynolds number
    # then, enable Reynolds, Mach, and rotational corrections

    (info, Re, Mach, alpha, cl, cd) = CCBlade.parsefile(af_fname, false)

    # Extend the angle of attack with the Viterna method.
    (alpha, cl, cd) = CCBlade.viterna(alpha, cl, cd, cr75)
    ### af = CCBlade.AlphaAF(alpha, cl, cd, info, Re, Mach)

    # smoothing the Viterna extrapolation curve by coarse interpolation
    alpha2 = Vector(range(-pi, pi, length=50))
    cl2 = FLOWMath.linear(alpha, cl, alpha2)
    cd2 = FLOWMath.linear(alpha, cd, alpha2)
    # return a smoother interpolation model to be used
    af = CCBlade.AlphaAF(alpha2, cl2, cd2, info, Re, Mach)

    # Reynolds number correction. The 0.6 factor seems to match the NACA 0012
    # drag data from airfoiltools.com.
    ### reynolds = CCBlade.SkinFriction(Re, Re_exp)  # this correction is probably not accurate for high angle-of-attack
    reynolds = nothing

    # Mach number correction.
    ### mach = CCBlade.PrandtlGlauert()
    mach = nothing

    # Rotational stall delay correction. Need some parameters from the CL curve.
    m, alpha0 = CCBlade.linearliftcoeff(af, 1.0, 1.0)  # dummy values for Re and Mach
    # Create the Du Selig and Eggers correction.
    ### rotation = CCBlade.DuSeligEggers(1.0, 1.0, 1.0, m, alpha0)   # NOTE: this doesn't work with optimization...
    rotation = nothing

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
    alpha_all = Vector(range(-pi, pi, length=50))   # coarse alpha discretization for smoothing
    Re_all = zeros(num_Re + 2)
    cl_all = zeros(50, num_Re + 2)   # Repeat the data for min and max Reynolds number for "extrapolation"
    cd_all = zeros(50, num_Re + 2)

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
    ### rotation = CCBlade.DuSeligEggers(1.0, 1.0, 1.0, m, alpha0)   # NOTE: this doesn't work with optimization...
    rotation = nothing

    # The usual hub and tip loss correction.
    tip = CCBlade.PrandtlTipHub()

    return af, mach, reynolds, rotation, tip
end

export get_rows_cols

function get_rows_cols(ss_sizes, of_ss, wrt_ss)
    # Get the output subscript, which will start with the of_ss, then the
    # wrt_ss with the subscripts common to both removed.
    # deriv_ss = of_ss + "".join(set(wrt_ss) - set(of_ss))
    deriv_ss = vcat(of_ss, setdiff(wrt_ss, of_ss))

    # Reverse the subscripts so they work with column-major ordering.
    of_ss = reverse(of_ss)
    wrt_ss = reverse(wrt_ss)
    deriv_ss = reverse(deriv_ss)

    # Get the shape of the output variable (the "of"), the input variable
    # (the "wrt"), and the derivative (the Jacobian).
    of_shape = Tuple(ss_sizes[s] for s in of_ss)
    wrt_shape = Tuple(ss_sizes[s] for s in wrt_ss)
    deriv_shape = Tuple(ss_sizes[s] for s in deriv_ss)

    # Invert deriv_ss: get a dictionary that goes from subscript to index
    # dimension.
    deriv_ss2idx = Dict(ss=>i for (i, ss) in enumerate(deriv_ss))

    # This is the equivalent of the Python code
    #   a = np.arange(np.prod(of_shape)).reshape(of_shape)
    #   b = np.arange(np.prod(wrt_shape)).reshape(wrt_shape)
    # but in column major order, which is OK, since we've reversed the order of
    # of_shape and wrt_shape above.
    a = reshape(0:prod(of_shape)-1, of_shape)
    b = reshape(0:prod(wrt_shape)-1, wrt_shape)

    rows = Array{Int}(undef, deriv_shape)
    cols = Array{Int}(undef, deriv_shape)
    for deriv_idx in CartesianIndices(deriv_shape)
        # Go from the jacobian index to the of and wrt indices.
        of_idx = [deriv_idx[deriv_ss2idx[ss]] for ss in of_ss]
        wrt_idx = [deriv_idx[deriv_ss2idx[ss]] for ss in wrt_ss]

        # Get the flattened index for the output and input.
        rows[deriv_idx] = a[of_idx...]
        cols[deriv_idx] = b[wrt_idx...]
    end

    # Return flattened versions of the rows and cols arrays.
    return rows[:], cols[:]
end

get_rows_cols(; ss_sizes, of_ss, wrt_ss) = get_rows_cols(ss_sizes, of_ss, wrt_ss)