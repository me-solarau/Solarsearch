-- Coverage is measured in FEET, not photographs.
--
-- Johan: "it is possible to shoot with two or more feet in view." The spot check
-- asks for half the feet on the job — 18 of 36 on an 18-panel array — but that
-- was being enforced as 18 separate photos. An installer who frames four feet in
-- one shot has evidenced four feet and should be credited with four.
--
-- The checker already looks at the image, so it counts what it can see and the
-- app totals it. Stored separately from the verdict because it is a measurement,
-- not a judgement: a photo can show six feet and still be non-compliant.
alter table public.install_photos add column if not exists ai_count integer;
comment on column public.install_photos.ai_count is
  'How many countable items of the step subject are clearly visible in this photo '
  '(e.g. mounting feet). Drives coverage targets so one wide shot can evidence '
  'several items. Null when the step has nothing to count.';
