' Launches ComfyUI silently (no console window), bound to 0.0.0.0:8188 for OWUI access.
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "E:\ai\comfyui\ComfyUI"
sh.Run """E:\ai\comfyui\ComfyUI\.venv\Scripts\python.exe"" main.py --listen 0.0.0.0 --port 8188", 0, False





