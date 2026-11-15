-- Apply to the dedicated StageSight project using the Supabase SQL editor.
-- Metadata lives in Postgres; videos live in a private Storage bucket.
begin;
create table public.sessions (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id),
  title text not null check (char_length(title) between 1 and 100),
  type text not null default 'Practice session',
  created_at timestamptz not null default now(),
  duration double precision not null default 0 check (duration >= 0),
  transcript text,
  storage_path text not null unique,
  status text not null default 'uploading' check (status in ('uploading','ready','failed','deleting')),
  mime_type text,
  byte_size bigint check (byte_size >= 0),
  constraint owner_storage_path check (storage_path = user_id::text || '/' || id::text || '/recording')
);
create index sessions_owner_created on public.sessions(user_id, created_at desc);
alter table public.sessions enable row level security;
revoke all on public.sessions from anon;
grant select, insert, update, delete on public.sessions to authenticated;
create policy "Read own sessions" on public.sessions for select to authenticated using (user_id = (select auth.uid()));
create policy "Insert own sessions" on public.sessions for insert to authenticated with check (user_id = (select auth.uid()));
create policy "Update own sessions" on public.sessions for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Delete own sessions" on public.sessions for delete to authenticated using (user_id = (select auth.uid()));
insert into storage.buckets (id,name,public,file_size_limit)
values ('recordings','recordings',false,52428800);
create policy "Read own recording objects" on storage.objects for select to authenticated
using (bucket_id = 'recordings' and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy "Upload own recording objects" on storage.objects for insert to authenticated
with check (bucket_id = 'recordings' and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy "Retry own recording uploads" on storage.objects for update to authenticated
using (bucket_id = 'recordings' and (storage.foldername(name))[1] = (select auth.uid()::text))
with check (bucket_id = 'recordings' and (storage.foldername(name))[1] = (select auth.uid()::text));
create policy "Delete own recording objects" on storage.objects for delete to authenticated
using (bucket_id = 'recordings' and (storage.foldername(name))[1] = (select auth.uid()::text));
commit;
