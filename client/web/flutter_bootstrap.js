{{flutter_js}}
{{flutter_build_config}}

const mainJsVersion = '20260616-2307';
const dart2jsBuild = _flutter.buildConfig.builds.find(
  (build) => build.compileTarget === 'dart2js',
);
if (dart2jsBuild && dart2jsBuild.mainJsPath === 'main.dart.js') {
  dart2jsBuild.mainJsPath = `main.dart.js?v=${mainJsVersion}`;
}

_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
    fontFallbackBaseUrl: "assets/fallback_fonts/",
  },
});
