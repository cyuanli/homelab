-- Repair Immich asset paths whose Latin-1 umlaut bytes were mapped into the
-- Unicode Private Use Area on import: U+EFE4/U+EFF6/U+EFFC instead of ä/ö/ü
-- (the Latin-1 byte plus 0xEF00). Verified 2026-09-25: 22 affected assets, and
-- for all 22 the repaired path exists on disk with a SHA-1 matching
-- asset.checksum. This corrects pointers only; no file is touched.
--
-- Reverse with undo-immich-pua-fix.sql, which carries the exact prior values.

BEGIN;

UPDATE asset
SET "originalPath"     = translate("originalPath",     U&'\EFE4\EFF6\EFFC', U&'\00E4\00F6\00FC'),
    "originalFileName" = translate("originalFileName", U&'\EFE4\EFF6\EFFC', U&'\00E4\00F6\00FC')
WHERE "deletedAt" IS NULL
  AND ("originalPath" ~ '[-]' OR "originalFileName" ~ '[-]');

-- Abort the whole transaction unless every PUA character is gone.
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM asset
    WHERE "originalPath" ~ '[-]' OR "originalFileName" ~ '[-]';
    IF n <> 0 THEN
        RAISE EXCEPTION 'aborting: % rows still contain PUA characters', n;
    END IF;
END $$;

COMMIT;
