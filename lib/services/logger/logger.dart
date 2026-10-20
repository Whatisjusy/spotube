import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide join;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotube/utils/platform.dart';
import 'package:logging/logging.dart' as logging;

final _loggingToLoggerLevel = {
  logging.Level.ALL: Level.all,
  logging.Level.FINEST: Level.trace,
  logging.Level.FINER: Level.debug,
  logging.Level.FINE: Level.info,
  logging.Level.CONFIG: Level.info,
  logging.Level.INFO: Level.info,
  logging.Level.WARNING: Level.warning,
  logging.Level.SEVERE: Level.error,
  logging.Level.SHOUT: Level.fatal,
  logging.Level.OFF: Level.off,
};

class AppLogger {
  static late final Logger log;
  static late final File logFile;

  static initialize(bool verbose) {
    // Release builds on iPhone also keep info lines (source picks, format
    // fallbacks, plugin timings) in the log file, so phone playback can be
    // checked afterwards. The default filter drops everything in release.
    final keepInFile = kReleaseMode && kIsIOS;
    log = Logger(
      level: kDebugMode || (verbose && kReleaseMode) ? Level.all : Level.info,
      filter: keepInFile ? ProductionFilter() : null,
      printer: keepInFile ? SimplePrinter(printTime: true, colors: false) : null,
      output: keepInFile ? _LogFileOutput() : null,
    );
  }

  static void _initInternalPackageLoggers() {
    if (!kDebugMode) return;
    logging.hierarchicalLoggingEnabled = true;
    logging.Logger('YoutubeExplode.StreamsClient')
      ..level = logging.Level.SEVERE
      ..onRecord.listen(
        (record) {
          log.log(
            _loggingToLoggerLevel[record.level] ?? Level.info,
            record.message,
            error: record.error,
            stackTrace: record.stackTrace,
            time: record.time,
          );
        },
      );
  }

  static R? runZoned<R>(R Function() body) {
    return runZonedGuarded<R>(
      () {
        WidgetsFlutterBinding.ensureInitialized();

        FlutterError.onError = (details) {
          reportError(details.exception, details.stack ?? StackTrace.current);
        };

        PlatformDispatcher.instance.onError = (error, stackTrace) {
          reportError(error, stackTrace);
          return true;
        };

        if (!kIsWeb) {
          Isolate.current.addErrorListener(
            RawReceivePort((pair) async {
              final isolateError = pair as List<dynamic>;
              reportError(
                isolateError.first.toString(),
                isolateError.last,
              );
            }).sendPort,
          );
        }

        _initInternalPackageLoggers();

        getLogsPath().then((value) => logFile = value);

        return body();
      },
      (error, stackTrace) {
        reportError(error, stackTrace);
      },
    );
  }

  static Future<File> getLogsPath() async {
    String dir = (await getApplicationDocumentsDirectory()).path;
    if (kIsAndroid) {
      dir = (await getExternalStorageDirectory())?.path ?? "";
    }

    if (kIsMacOS) {
      dir = join((await getLibraryDirectory()).path, "Logs");
    }

    if (kIsLinux) {
      dir = join(_getXdgStateHome(), "spotube");
    }

    final file = File(join(dir, ".spotube_logs"));
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    // The iPhone log also gets info lines; start fresh past 5 MB.
    if (kIsIOS && await file.length() > 5 * 1024 * 1024) {
      await file.writeAsString("");
    }
    return file;
  }

  static Future<void> reportError(
    dynamic error, [
    StackTrace? stackTrace,
    message = "",
  ]) async {
    log.e(message, error: error, stackTrace: stackTrace);

    if (kReleaseMode) {
      await logFile.writeAsString(
        "[${DateTime.now()}]---------------------\n"
        "$error\n$stackTrace\n"
        "----------------------------------------\n",
        mode: FileMode.writeOnlyAppend,
      );
    }
  }

  static String _getXdgStateHome() {
    // path_provider seems does not support XDG_STATE_HOME,
    // which is the specification to store application logs on Linux.
    // See https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
    // TODO: Use path_provider once it supports XDG_STATE_HOME
    if (const bool.hasEnvironment("XDG_STATE_HOME")) {
      String xdgStateHomeRaw = Platform.environment["XDG_STATE_HOME"] ?? "";
      if (xdgStateHomeRaw.isNotEmpty) {
        return xdgStateHomeRaw;
      }
    }
    return join(Platform.environment["HOME"] ?? "", ".local", "state");
  }
}

class _LogFileOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    try {
      AppLogger.logFile.writeAsStringSync(
        "${event.lines.join("\n")}\n",
        mode: FileMode.writeOnlyAppend,
      );
    } catch (_) {
      // logFile is set a moment after start-up; earlier lines are dropped.
    }
  }
}

class AppLoggerProviderObserver extends ProviderObserver {
  const AppLoggerProviderObserver();

  @override
  void providerDidFail(
    ProviderBase<Object?> provider,
    Object error,
    StackTrace stackTrace,
    ProviderContainer container,
  ) {
    AppLogger.reportError(error, stackTrace);
  }
}
