# Test stand-in for the ComfyUI venv's python, used only by
# tests/Sync-StackManifests.Tests.ps1. It answers '--version' and
# '-m pip freeze'. $env:CRIA_FAKE_PIP:
#   fail   pip freeze fails
#   local  one package was installed from a local file
#   cpu    torch is a build without CUDA
#   leak   one package was installed from a URL with a token in it
#   anything else: a CUDA torch and two other packages, out of order
if ($args.Count -eq 1 -and $args[0] -eq '--version') { 'Python 3.11.9'; exit 0 }
if ($args.Count -eq 3 -and $args[0] -eq '-m' -and $args[1] -eq 'pip' -and $args[2] -eq 'freeze') {
    $mode = $env:CRIA_FAKE_PIP
    if ($mode -eq 'fail') { exit 1 }
    'aiohttp==3.10.5'
    if ($mode -eq 'cpu') { 'torch==2.5.1' } else { 'torch==2.5.1+cu124' }
    'Pillow==10.4.0'
    if ($mode -eq 'local') { 'mypkg @ file:///C:/build/mypkg' }
    if ($mode -eq 'leak') { 'privpkg @ git+https://' + 'ghp_' + ('x' * 36) + '@github.com/example/privpkg.git' }
    exit 0
}
exit 1
