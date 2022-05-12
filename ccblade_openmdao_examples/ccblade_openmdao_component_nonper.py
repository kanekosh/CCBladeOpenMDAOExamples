import os

from julia import Main

# Copy of ccblade_openmdao_component.py, but includes the modified wrapper with non-perpendicular inflow
script_dir = os.path.dirname(os.path.realpath(__file__))
Main.include(os.path.join(script_dir, "ccblade_openmdao_component_nonper.jl"))

BEMTRotorCAComp = Main.BEMTRotorCACompSideFlow
