{
  lib,
  stdenvNoCC,
  fetchurl,
  undmg,
  nix-update-script,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "stats";
  version = "2.10.16";

  src = fetchurl {
    url = "https://github.com/exelban/stats/releases/download/v${finalAttrs.version}/Stats.dmg";
    hash = "sha256-fSn4qZMXRlWxqIZ2Jh1anLQPbx/TqHA7UFRq+pR3o+4=";
  };

  sourceRoot = ".";

  nativeBuildInputs = [ undmg ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/Applications
    cp -r *.app $out/Applications

    runHook postInstall
  '';

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "macOS system monitor in your menu bar";
    homepage = "https://github.com/exelban/stats";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [
      donteatoreo
      emilytrau
      Enzime
    ];
    platforms = lib.platforms.darwin;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
