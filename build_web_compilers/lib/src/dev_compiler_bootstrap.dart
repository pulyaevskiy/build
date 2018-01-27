// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:build/build.dart';
import 'package:path/path.dart' as _p; // ignore: library_prefixes

import 'dev_compiler_builder.dart';
import 'module_builder.dart';
import 'modules.dart';
import 'web_entrypoint_builder.dart';

/// Alias `_p.url` to `p`.
_p.Context get p => _p.url;

Future<Null> bootstrapDdc(BuildStep buildStep,
    {bool useKernel, bool buildRootAppSummary}) async {
  useKernel ??= false;
  buildRootAppSummary ??= false;
  var dartEntrypointId = buildStep.inputId;
  var moduleId = buildStep.inputId.changeExtension(moduleExtension);
  var module = new Module.fromJson(JSON
      .decode(await buildStep.readAsString(moduleId)) as Map<String, dynamic>);

  if (buildRootAppSummary) await buildStep.canRead(module.linkedSummaryId);

  // First, ensure all transitive modules are built.
  var transitiveDeps = await _ensureTransitiveModules(module, buildStep);

  var appModuleName = _ddcModuleName(module.jsId);

  // The name of the entrypoint dart library within the entrypoint JS module.
  //
  // This is used to invoke `main()` from within the bootstrap script.
  //
  // TODO(jakemac53): Sane module name creation, this only works in the most
  // basic of cases.
  //
  // See https://github.com/dart-lang/sdk/issues/27262 for the root issue
  // which will allow us to not rely on the naming schemes that dartdevc uses
  // internally, but instead specify our own.
  var appModuleScope = () {
    if (useKernel) {
      var basename = p.basename(module.jsId.path);
      return basename.substring(0, basename.length - jsModuleExtension.length);
    } else {
      return p.split(_ddcModuleName(module.jsId)).skip(1).join('__');
    }
  }();
  appModuleScope = appModuleScope.replaceAll('.', '\$46');

  // Map from module name to module path for custom modules.
  var modulePaths = {'dart_sdk': 'packages/\$sdk/dev_compiler/common/dart_sdk'};
  var transitiveJsModules = [module.jsId]
    ..addAll(transitiveDeps.map((dep) => dep.jsId));
  for (var jsId in transitiveJsModules) {
    // Strip out the top level dir from the path for any module, and set it to
    // `packages/` for lib modules. We set baseUrl to `/` to simplify things,
    // and we only allow you to serve top level directories.
    var moduleName = _ddcModuleName(jsId);
    modulePaths[moduleName] = p.withoutExtension(jsId.path.startsWith('lib')
        ? '$moduleName$jsModuleExtension'
        : p.joinAll(p.split(jsId.path).skip(1)));
  }

  var bootstrapContent = new StringBuffer('(function() {\n');
  bootstrapContent.write(_dartLoaderSetup(modulePaths));
  // bootstrapContent.write(_requireJsConfig);

  bootstrapContent.write(_appBootstrap(appModuleName, appModuleScope));

  var bootstrapId = dartEntrypointId.changeExtension(ddcBootstrapExtension);
  await buildStep.writeAsString(bootstrapId, bootstrapContent.toString());

  var bootstrapModuleName = p.withoutExtension(
      p.relative(bootstrapId.path, from: p.dirname(dartEntrypointId.path)));

  var entrypointJsContent = _entryPointJs(bootstrapModuleName);
  await buildStep.writeAsString(
      dartEntrypointId.changeExtension(jsEntrypointExtension),
      entrypointJsContent);
  await buildStep.writeAsString(
      dartEntrypointId.changeExtension(jsEntrypointSourceMapExtension),
      '{"version":3,"sourceRoot":"","sources":[],"names":[],"mappings":"",'
      '"file":""}');
}

/// Ensures that all transitive js modules for [module] are available and built.
Future<List<Module>> _ensureTransitiveModules(
    Module module, AssetReader reader) async {
  // Collect all the modules this module depends on, plus this module.
  var transitiveDeps = await module.computeTransitiveDependencies(reader);
  var jsModules = transitiveDeps.map((module) => module.jsId).toList()
    ..add(module.jsId);
  // Check that each module is readable, and warn otherwise.
  await Future.wait(jsModules.map((jsId) async {
    if (await reader.canRead(jsId)) return;
    log.warning(
        'Unable to read $jsId, check your console for compilation errors.');
  }));
  return transitiveDeps;
}

/// The module name according to ddc for [jsId] which represents the real js
/// module file.
String _ddcModuleName(AssetId jsId) {
  var jsPath = jsId.path.startsWith('lib/')
      ? jsId.path.replaceFirst('lib/', 'packages/${jsId.package}/')
      : jsId.path;
  return jsPath.substring(0, jsPath.length - jsModuleExtension.length);
}

/// Code that actually imports the [moduleName] module, and calls the
/// `[moduleScope].main()` function on it.
///
/// Also performs other necessary initialization.
String _appBootstrap(String moduleName, String moduleScope) => '''
  const app = require("$moduleName");
  dart_sdk._isolate_helper.startRootIsolate(() => {}, []);
  app.$moduleScope.main();
})();
''';

/// The actual entrypoint JS file which injects all the necessary scripts to
/// run the app.
String _entryPointJs(String bootstrapModuleName) => '''
(function() {
  require("./$bootstrapModuleName");
})();
''';

/// JavaScript snippet to determine the directory a script was run from.
final _currentDirectoryScript = r'''
var _currentDirectory = (function () {
  var _url;
  var lines = new Error().stack.split('\n');
  function lookupUrl() {
    if (lines.length > 2) {
      var match = lines[1].match(/^\s+at (.+):\d+:\d+$/);
      // Chrome.
      if (match) return match[1];
      // Chrome nested eval case.
      match = lines[1].match(/^\s+at eval [(](.+):\d+:\d+[)]$/);
      if (match) return match[1];
      // Edge.
      match = lines[1].match(/^\s+at.+\((.+):\d+:\d+\)$/);
      if (match) return match[1];
      // Firefox.
      match = lines[0].match(/[<][@](.+):\d+:\d+$/)
      if (match) return match[1];
    }
    // Safari.
    return lines[0].match(/(.+):\d+:\d+$/)[1];
  }
  _url = lookupUrl();
  var lastSlash = _url.lastIndexOf('/');
  if (lastSlash == -1) return _url;
  var currentDirectory = _url.substring(0, lastSlash + 1);
  return currentDirectory;
})();
''';

/// Sets up `window.$dartLoader` based on [modulePaths].
String _dartLoaderSetup(Map<String, String> modulePaths) => '''

  let modulePaths = ${const JsonEncoder.withIndent(" ").convert(modulePaths)};

  const path = require('path');

  /// Resolves module [id] for Dart package names to their absolute filenames.
  /// Regular NodeJS module IDs are returned as-is.
  function resolveId(id) {
    if (id in modulePaths) {
      var parts = require.main.filename.split(path.sep);
      parts.pop();
      parts.push(modulePaths[id]);
      var newId = parts.join(path.sep);
      return newId;
    }
    return id;
  };

  // Override built-in `Module.require` function to resolve Dart package
  // names to their absolute filename paths.
  var Module = require('module');
  var moduleRequire = Module.prototype.require;
  Module.prototype.require = function () {
    var id = arguments['0'];
    arguments['0'] = resolveId(id);
    return moduleRequire.apply(this, arguments);
  };
  // From this point each call to `require` will be able to resolve Dart package
  // names.

  const dart_sdk = require("dart_sdk");
  const dart = dart_sdk.dart;

  // There is a JS binding for `require` function in `node` package.
  // DDC treats this binding as global and maps all calls to this function
  // in Dart code to `dart.global.require`. We define this function here as a 
  // proxy to our own require function.
  dart.global.require = function (id) {
    return require(id);
  }
''';

/// Code to initialize the dev tools formatter, stack trace mapper, and any
/// other tools.
///
/// Posts a message to the window when done.
final _initializeTools = '''
  dart_sdk._debugger.registerDevtoolsFormatter();
  if (window.\$dartStackTraceUtility && !window.\$dartStackTraceUtility.ready) {
    window.\$dartStackTraceUtility.ready = true;
    let dart = dart_sdk.dart;
    window.\$dartStackTraceUtility.setSourceMapProvider(
      function(url) {
        var module = window.\$dartLoader.urlToModuleId.get(url);
        if (!module) return null;
        return dart.getSourceMap(module);
      });
  }
  window.postMessage({ type: "DDC_STATE_CHANGE", state: "start" }, "*");
''';

/// Require JS config for ddc.
///
/// Sets the base url to `/` so that all modules can be loaded using absolute
/// paths which simplifies a lot of scenarios.
///
/// Sets the timeout for loading modules to infinity (0).
///
/// Sets up the custom module paths.
///
/// Adds error handler code for require.js which requests a `.errors` file for
/// any failed module, and logs it to the console.
final _requireJsConfig = '''
// Whenever we fail to load a JS module, try to request the corresponding
// `.errors` file, and log it to the console.
(function() {
  var oldOnError = requirejs.onError;
  requirejs.onError = function(e) {
    if (e.originalError && e.originalError.srcElement) {
      var xhr = new XMLHttpRequest();
      xhr.onreadystatechange = function() {
        if (this.readyState == 4 && this.status == 200) {
          console.error(this.responseText);
          var errorEvent = new CustomEvent(
            'dartLoadException', { detail: this.responseText });
          window.dispatchEvent(errorEvent);
        }
      };
      xhr.open("GET", e.originalError.srcElement.src + ".errors", true);
      xhr.send();
    }
    // Also handle errors the normal way.
    if (oldOnError) oldOnError(e);
  };
}());

$_baseUrlScript;

require.config({
    baseUrl: baseUrl,
    waitSeconds: 0,
    paths: customModulePaths
});
''';

final _baseUrlScript = '''
// Attempt to detect --precompiled mode for tests, and set the base url
// appropriately, otherwise set it to "/".
var baseUrl = (function() {
  var pathParts = location.pathname.split("/");
  if (pathParts[0] == "") {
    pathParts.shift();
  }
  var baseUrl;
  if (pathParts.length > 1 && pathParts[1] == "test") {
    return "/" + pathParts.slice(0, 2).join("/") + "/";
  }
  return "/";
}());
''';
