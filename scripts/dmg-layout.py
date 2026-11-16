# /// script
# requires-python = ">=3.10"
# dependencies = ["ds-store==1.3.4", "mac-alias==2.2.4"]
# ///
"""Write Finder layout without opening Finder or using desktop automation."""
import sys
from pathlib import Path
from ds_store import DSStore
from mac_alias import Alias

root = Path(sys.argv[1])
background = Alias.for_file(str(root / ".background" / "installer.png")).to_bytes()
with DSStore.open(str(root / ".DS_Store"), "w+") as store:
    store["."]["bwsp"] = {
        "ShowStatusBar": False, "ShowTabView": False, "ShowToolbar": False,
        "ShowPathbar": False, "ShowSidebar": False, "ContainerShowSidebar": False,
        "WindowBounds": "{{180, 180}, {660, 440}}",
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1, "backgroundType": 2,
        "backgroundColorRed": 0.0, "backgroundColorGreen": 0.0, "backgroundColorBlue": 0.0,
        "backgroundImageAlias": background,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
        "arrangeBy": "none", "showIconPreview": False, "showItemInfo": False,
        "labelOnBottom": True, "textSize": 13.0, "iconSize": 104.0,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    }
    store["."]["vSrn"] = ("long", 1)
    store["."]["vstl"] = ("type", b"icnv")
    store["SuperCopy.app"]["Iloc"] = (174, 220)
    store["Applications"]["Iloc"] = (486, 220)
with DSStore.open(str(root / ".DS_Store"), "r") as store:
    assert store["SuperCopy.app"]["Iloc"] == (174, 220)
    assert store["Applications"]["Iloc"] == (486, 220)
    assert store["."]["icvp"]["backgroundImageAlias"] == background
print("Finder layout written and read back successfully")
