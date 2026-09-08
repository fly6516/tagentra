# Third-party notices

Tagentra's Apple PM3 core build consumes the upstream
[RRG/Iceman Proxmark3 project](https://github.com/RfidResearchGroup/proxmark3).
RRG Proxmark3 and the Tagentra compatibility shim are distributed under the
GNU General Public License, version 3 or (at your option) any later version.

The generated `TagentraPM3Core.xcframework` contains RRG client code and the
libraries selected by RRG's `client/experimental_lib/CMakeLists.txt`. Their
copyright notices and license texts remain in the corresponding upstream
source tree. When distributing a generated binary, distribute the complete
corresponding source for the exact revision recorded in
`TagentraPM3Core-build.json`, including this repository's shim and build
scripts, as required by the applicable licenses.

Tagentra is an independent project. Proxmark3 is a trademark or project name
of its respective owners; no endorsement is implied.
