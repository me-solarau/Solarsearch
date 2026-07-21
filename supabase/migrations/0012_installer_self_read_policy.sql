-- NOT YET APPLIED to the live project (declined during the session) — apply
-- when ready. Without it the installer portal still works fully (board/seat
-- go through SECURITY DEFINER RPCs); only the header company-name lookup
-- returns null and the header keeps its default text.
--
-- An installer can read only its own installers row (for company name / brand
-- in the portal header). All board/seat/quote access still goes exclusively
-- through the SECURITY DEFINER RPCs — this policy exposes nothing else.
create policy installer_self_read on public.installers for select to authenticated
  using (auth_uid = auth.uid());
