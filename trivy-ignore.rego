# Julia 1.12.7 ships these JLLs as stdlib. `Pkg.add` / `Pkg.update` of a
# newer General-registry build resolves back to the runtime pin, so the
# "fixed version" Trivy reports is not installable in this tree.
# LibGit2_jll is pulled into qa/Manifest.toml via Aqua -> Pkg and stays
# at 1.9.0+0 for the same reason.
package trivy

default ignore = false

julia_stdlib_jlls := {
	"LibCURL_jll",
	"LibGit2_jll",
	"LibSSH2_jll",
	"OpenSSL_jll",
	"Zlib_jll",
	"nghttp2_jll",
	"p7zip_jll",
}

ignore {
	input.PkgName == julia_stdlib_jlls[_]
}
