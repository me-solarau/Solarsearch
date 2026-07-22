-- Let installers read/write their install evidence in the existing assessment-photos bucket,
-- scoped to the install/ path prefix (install.html uploads to install/<install_id>/...).
-- (A dedicated install-photos bucket was declined; this reuses the existing bucket.)
create policy install_prefix_rw on storage.objects for all to authenticated
  using (
    bucket_id = 'assessment-photos'
    and (storage.foldername(name))[1] = 'install'
    and (public.current_installer_id() is not null or public.is_admin())
  )
  with check (
    bucket_id = 'assessment-photos'
    and (storage.foldername(name))[1] = 'install'
    and (public.current_installer_id() is not null or public.is_admin())
  );
