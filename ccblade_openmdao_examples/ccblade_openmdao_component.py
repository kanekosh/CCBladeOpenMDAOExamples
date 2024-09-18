import os

# Create a new Julia module that will hold all the Julia code imported into this Python module.
import juliacall
juliamodule = juliacall.newmodule("RotorAnalysis")

script_dir = os.path.dirname(os.path.realpath(__file__))
juliamodule.include(os.path.join(script_dir, "ccblade_openmdao_component.jl"))
