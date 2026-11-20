import 'dart:io';
import 'package:excel/excel.dart';
import 'package:path/path.dart' as p;
import '../models/app_settings.dart';
import '../models/scenario_models.dart';
import 'app_paths.dart';

class ExcelExportResult {
  final String savedPath;
  final bool usedBackup;
  final int rowCount;

  const ExcelExportResult({
    required this.savedPath,
    required this.usedBackup,
    required this.rowCount,
  });
}

/// Экспорт и пересборка результатов сценариев в UserData/Excel/scenario_results.xlsx (лист «Результаты»).
/// Поддерживает настройку колонок, цветовое выделение СОВПАЛ / НЕ СОВПАЛ и резервное сохранение при блокировке файла.
class ExcelExporter {
  static const String sheetName = 'Результаты';

  static Future<ExcelExportResult> rebuildFromRuns({
    required List<ScenarioRunRecord> runs,
    required List<ExcelColumnSpec> columns,
  }) async {
    await AppPaths.ensureDirectories();
    final activeCols = columns.where((c) => c.enabled).toList();
    final effectiveCols =
        activeCols.isNotEmpty ? activeCols : ExcelColumnSpec.defaults();

    final excel = Excel.createExcel();
    final defaultSheet = excel.getDefaultSheet();
    if (defaultSheet != null && defaultSheet != sheetName) {
      excel.rename(defaultSheet, sheetName);
    }
    final sheet = excel[sheetName];

    final headerStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#1E293B'),
      fontColorHex: ExcelColor.fromHexString('#FFFFFF'),
      horizontalAlign: HorizontalAlign.Center,
    );

    final matchStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#DCFCE7'),
      fontColorHex: ExcelColor.fromHexString('#166534'),
      horizontalAlign: HorizontalAlign.Center,
    );

    final mismatchStyle = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#FEE2E2'),
      fontColorHex: ExcelColor.fromHexString('#991B1B'),
      horizontalAlign: HorizontalAlign.Center,
    );

    // Заголовки
    for (var colIdx = 0; colIdx < effectiveCols.length; colIdx++) {
      final cell = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: colIdx, rowIndex: 0),
      );
      cell.value = TextCellValue(effectiveCols[colIdx].header);
      cell.cellStyle = headerStyle;
      sheet.setColumnWidth(colIdx, 20);
    }

    // Строки прогонов
    for (var rowIdx = 0; rowIdx < runs.length; rowIdx++) {
      final run = runs[rowIdx];
      for (var colIdx = 0; colIdx < effectiveCols.length; colIdx++) {
        final col = effectiveCols[colIdx];
        final val = run.fieldValue(col.key);
        final cell = sheet.cell(
          CellIndex.indexByColumnRow(columnIndex: colIdx, rowIndex: rowIdx + 1),
        );

        if ((col.key == 'firstBalance' ||
                col.key == 'lastBalance' ||
                col.key == 'balanceDiff') &&
            val.isNotEmpty) {
          final numVal = double.tryParse(val);
          cell.value =
              numVal != null ? DoubleCellValue(numVal) : TextCellValue(val);
        } else if (col.key == 'durationSec') {
          cell.value = IntCellValue(run.durationSec);
        } else {
          cell.value = TextCellValue(val);
        }

        if (col.key == 'balanceMatchStatus') {
          if (val == 'СОВПАЛ') {
            cell.cellStyle = matchStyle;
          } else if (val == 'НЕ СОВПАЛ') {
            cell.cellStyle = mismatchStyle;
          }
        }
      }
    }

    final encoded = excel.encode();
    if (encoded == null) {
      throw StateError('Не удалось сформировать бинарный файл Excel.');
    }

    final mainPath = AppPaths.excelMainFile;
    try {
      final file = File(mainPath);
      await file.writeAsBytes(encoded, flush: true);
      return ExcelExportResult(
        savedPath: mainPath,
        usedBackup: false,
        rowCount: runs.length,
      );
    } on FileSystemException {
      // Файл открыт в Excel — сохраняем резервную копию рядом
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp =
          '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
      final backupPath =
          p.join(AppPaths.excelDir, 'scenario_results_backup_$stamp.xlsx');
      await File(backupPath).writeAsBytes(encoded, flush: true);
      return ExcelExportResult(
        savedPath: backupPath,
        usedBackup: true,
        rowCount: runs.length,
      );
    }
  }
}
