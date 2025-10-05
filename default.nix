{
  stdenv,
  lib,
  zigPackage,
  raylib,
}:
stdenv.mkDerivation {
  pname = "Wayland Client";
  version = "0.1.0";

  src = ./.;
  XDG_CACHE_HOME = "${placeholder "out"}";

  buildInputs = [ raylib ];
  nativeBuildInputs = [ zigPackage ];

  buildPhase = ''
    ${zigPackage}/bin/zig build
  '';

  installPhase = ''
    ${zigPackage}/bin/zig build install --prefix $out
    rm -rf $out/zig
  '';

  meta = with lib; {
    description = "Wayland Client - A Zig application";
    homepage = "https://github.com/xendak/zigland";
    license = licenses.mit;
    maintainers = [ maintainers.xendak ];
    platforms = platforms.all;
  };
}
