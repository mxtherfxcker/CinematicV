#  CinematicV 

### Preview (Legacy)

<a href="https://github.com/mxtherfxcker/CinematicV/releases/latest">
<img width="1920" height="1080" alt="Preview #1" src="https://github.com/user-attachments/assets/3d78f006-e856-4ce3-ba69-6ce6ea109c9c" />
<img width="1920" height="1080" alt="Preview #2" src="https://github.com/user-attachments/assets/aefe0416-03ed-4b04-b833-fc415aafa7d1" />
</a>

### How to install  
**You need:**  
Alexander Blade's **ScriptHookV** or **Ultimate ASI Loader** (x64)  

1. Download ReShade from the official [website](https://reshade.me/) or [repository](https://github.com/crosire/reshade/tags).  
2. Setup ReShade for GTA V -
   1. Run `ReShade_Setup_x.x.x.exe`.
   2. Provide path to `GTA5.exe` or choose `GTA V` from the list.
   3. Select "DirectX 10/11/12".
   4. Provide path to `CinematicV.ini`.
   5. Wait and finish.
4. Find and rename the `dxgi.dll` file to `dxgi.asi` in your GTA V folder.
5. Place `AFP-BodycamLens.fx` in the following directory: `Your GTA V Folder`/`reshade-shaders`/`Shaders`/
6. Enjoy :)

### Usage recommendations

1. If you're running the **Legacy version**, make sure that "DirectX Version: **DirectX 11**" is selected in the GTA V graphics settings.
2. Enable **FXAA** and:
   1. Enable **MSAA x8** (Recommended) **OR** Enable **MSAA x4** and **TXAA** *(if supported)*.
   2. Make sure that **MSAA for reflections** is enabled (**x4** or **x8**).
   3. In the "**Soft Shadows**" parameter, set the value to "**Max. soft**" or "**NVIDIA PCSS**" *(if supported)*.  

# Other Information

> [!IMPORTANT]
> Be sure to adjust the brightness in the game's display settings! *(For me, it's ~50%)*.

> [!CAUTION]
> 1. I do not own the `AFP-BodycamLens.fx` file!  
>    It was taken from the [Alternate First Person](https://www.gta5-mods.com/scripts/alternate-first-person-enhanced-legacy) modification.  
> 2. Unexpected behavior may occur when used in conjunction with other major graphical modifications! (such as **NVE** or **QuantV**).  
> 3. After installing the preset, you may experience a **~30%** drop in performance!
