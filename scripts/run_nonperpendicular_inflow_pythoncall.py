"""
Python script to call CCBlade with non-perpendicular inflow.
Uses new python-julia coupling via omjlcomps
"""

import numpy as np
import matplotlib.pyplot as plt
import openmdao.api as om

from ccblade_openmdao_examples.ccblade_openmdao_component_nonper import juliamodule
from omjlcomps import JuliaImplicitComp


def get_problem():
    # --- blade definition --- 
    B = 3  # Number of blades.
    c = 0.060  # constant chord, m
    theta = 0.0   # constant twist, rad
    Rtip = 0.656
    Rhub = 0.19 * Rtip  # Just guessing on the hub diameter.

    # discretize blade
    num_radial = 30  # number of elements
    radii = np.linspace(Rhub, Rtip, num_radial)
    radii[0] += 1e-4
    radii[-1] -= 1e-4  # need these modif so that Rhub <= radii <= Rtip even when calling check_partials
    theta = np.ones(num_radial) * theta
    chord = np.ones(num_radial) * c

    # --- atmos conditions ---
    rho = 1.225
    T0 = 273.15 + 15.0
    gam = 1.4
    speedofsound = np.sqrt(gam*287.058*T0)

    # --- operatin condition ---
    # sweep pitch

    num_operating_points = 11
    ### pitch = np.linspace(5*np.pi/180, 20*np.pi/180, num_operating_points)  # rad
    ### Omega = 800 * np.pi / 30 * np.ones(num_operating_points)
    ### Vinf = -1.0 * np.ones(num_operating_points)
    pitch = 5 * np.pi / 180 * np.ones(num_operating_points)
    Omega = 800 * np.pi / 30 * np.ones(num_operating_points)
    Vinf = np.linspace(-3.0, 3.0, num_operating_points)
    Vinf[5] += 0.2   # exact 0 velocity will cause an issue

    # side velocity
    V_pal = np.linspace(3.0, 20.0, num_operating_points)

    """
    num_operating_points = 1
    pitch = 5*np.pi/180  # rad
    Omega = 800 * np.pi / 30
    Vinf = 1.0
    """

    # --- setup OpenMDAO problem ---
    prob = om.Problem()

    comp = om.IndepVarComp()
    comp.add_output("Rhub", val=Rhub, units="m")
    comp.add_output("Rtip", val=Rtip, units="m")
    comp.add_output("radii", val=radii, units="m")
    comp.add_output("chord", val=chord, units="m")
    comp.add_output("theta", val=theta, units="rad")
    comp.add_output("v", val=Vinf, shape=num_operating_points, units="m/s")
    comp.add_output("v_pal", val=V_pal, shape=num_operating_points, units="m/s")
    comp.add_output("omega", val=Omega, shape=num_operating_points, units="rad/s")
    comp.add_output("pitch", val=pitch, shape=num_operating_points, units="rad")
    prob.model.add_subsystem("inputs_comp", comp, promotes_outputs=["*"])

    # TODO: check Re_exp and airfoil model
    af_fname = "./data/xf-n0012-il-500000.dat"
    comp = JuliaImplicitComp(
        jlcomp=juliamodule.BEMTRotorCACompSideFlow(
            af_fname=af_fname, cr75=c / Rtip, Re_exp=0.6,
            num_operating_points=num_operating_points, num_blades=B,
            num_radial=num_radial, num_azimuth=7, rho=rho, mu=rho*1.461e-5, speedofsound=speedofsound))
    prob.model.add_subsystem("bemt_rotor_comp", comp, promotes_inputs=["Rhub", "Rtip", "radii", "chord", "theta", "v", "v_pal", "omega", "pitch"], promotes_outputs=["thrust", "torque", "drag"])
    # if num_azimuth=1, sideflow component will be ignored.

    prob.model.linear_solver = om.DirectSolver()
    ### prob.driver = om.pyOptSparseDriver(optimizer="SNOPT")

    ### prob.driver.opt_settings['Verify level'] = 3

    ### prob.model.add_design_var("chord", lower=0.01, upper=0.1, ref=1e-2, units='m')
    ### prob.model.add_design_var("theta", lower=5, upper=85, ref=1e0, units='deg')
    ### prob.model.add_objective("efficiency", ref=-1e0)
    ### prob.model.add_constraint("thrust", lower=thrust_target, upper=thrust_target, units="N", ref=1e2)

    prob.setup(check=True)

    return prob


if __name__ == "__main__":
    p = get_problem()
    print('------------------------')
    print('  done setup')
    print('------------------------')
    # om.n2(p, show_browser=False)
    # p.run_driver()
    p.run_model()
    ### om.n2(p, show_browser=False)
    p.check_partials(compact_print=True)

    thrust = p.get_val('thrust', units='N')
    torque = p.get_val('torque', units='N*m')
    ### fm = p.get_val('bemt_rotor_comp.figure_of_merit')
    print('thrust:', thrust)
    print('torque:', torque)
    print('drag:', p.get_val('drag', units='N'))
    ### print('FM:', fm)

    ### phi = p.get_val('bemt_rotor_comp.phi')
    ### print('phi_shape:', phi.shape)
    ### print(phi[0, 15, :])
    ### print(phi[0, 12, :])

    # plot
    vinf = p.get_val('v', units='m/s')
    plt.figure()
    plt.plot(vinf, thrust, 'o-')
    plt.xlabel('Vinf [m/s]')
    plt.ylabel('Thrust [N]')
    plt.grid()

    plt.figure()
    plt.plot(vinf, torque, 'o-')
    plt.xlabel('Vinf [m/s]')
    plt.ylabel('Torque [N-m]')
    plt.grid()

    plt.show()

    """
    radii_cp = p.get_val("radii_cp", units="inch")
    radii = p.get_val("radii", units="inch")
    chord_cp = p.get_val("chord_cp", units="inch")
    chord = p.get_val("chord", units="inch")
    theta_cp = p.get_val("theta_cp", units="deg")
    theta = p.get_val("theta", units="deg")

    cmap = plt.get_cmap("tab10")
    fig, (ax0, ax1) = plt.subplots(nrows=2, sharex=True)
    ax0.plot(radii_cp, chord_cp, color=cmap(0), marker="o")
    ax0.plot(radii, chord, color=cmap(0))
    ax0.set_ylim(0.0, 5.0)
    ax1.plot(radii_cp, theta_cp, color=cmap(0), marker="o")
    ax1.plot(radii, theta, color=cmap(0))
    fig.savefig("chord_theta.png")
    """