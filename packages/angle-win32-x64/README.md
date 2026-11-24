# @native-sdk/angle-win32-x64

ANGLE, the OpenGL ES implementation the Windows host runs WebGL 2 on, as the three libraries a
Windows app loads at run time: `libEGL.dll`, `libGLESv2.dll` and `d3dcompiler_47.dll`.

`@native-sdk/cli` lists this package as an optional dependency, so npm installs it on Windows x64
and nowhere else. A Windows build copies the libraries into the app's `<executable>.resources`,
and the host loads them from there before anywhere else, so the built app carries WebGL 2 with
it. `NATIVE_ANGLE_DIR` points a build at another ANGLE build instead.

The libraries and their provenance are described in [NOTICE](NOTICE); ANGLE's license is in
[LICENSE](LICENSE).
