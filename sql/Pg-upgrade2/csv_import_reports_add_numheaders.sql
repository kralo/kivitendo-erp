-- @tag: csv_import_reports_add_numheaders
-- @description: Anzahl der Header-Zeilen in Csv Import Report speichern
-- @depends: csv_import_report_cache
-- @encoding: utf-8

ALTER TABLE csv_import_reports ADD COLUMN numheaders INTEGER NOT NULL;
