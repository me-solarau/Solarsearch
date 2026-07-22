-- Content hashing for tamper-EVIDENCE (complements the immutability lock in 0050). A SHA-256
-- of the image bytes is captured at upload and frozen with the row on submission, so a later
-- swap of the storage object is detectable: re-hash the stored file and compare to sha256.
alter table public.assessment_photos add column if not exists sha256 text;
alter table public.assessment_photos add column if not exists bytes int;
