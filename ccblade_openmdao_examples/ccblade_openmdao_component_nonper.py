""" old PyCall/pyjulia version
import os

from julia import Main

# Copy of ccblade_openmdao_component.py, but includes the modified wrapper with non-perpendicular inflow
script_dir = os.path.dirname(os.path.realpath(__file__))
Main.include(os.path.join(script_dir, "ccblade_openmdao_component_nonper.jl"))

BEMTRotorCAComp = Main.BEMTRotorCACompSideFlow
"""

import os
import openmdao.api as om

# Create a new Julia module that will hold all the Julia code imported into this Python module.
import juliacall
juliamodule = juliacall.newmodule("RotorAnalysis")

script_dir = os.path.dirname(os.path.realpath(__file__))
juliamodule.include(os.path.join(script_dir, "ccblade_openmdao_component_nonper.jl"))

# Now we have access to everything in `paraboloid.jl`.

# omjlcomps knows how to create an OpenMDAO ExplicitComponent from an OpenMDAOCore.AbstractExplicitComp
# from omjlcomps import JuliaExplicitComp
# comp = JuliaExplicitComp(jlcomp=jl.Paraboloid())