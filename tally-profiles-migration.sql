-- =====================================================================
-- TALLY COMMUNITY 2.1 MIGRATION: personal trader profiles
-- Additive and idempotent: only NEW nullable columns on public.profiles, no existing data is touched.
-- Run once in the Supabase SQL editor (as postgres). Safe to run again.
-- Profile photos reuse the existing private bucket "post-images" (members read, only the owner writes "<user_id>/...").
-- =====================================================================

alter table public.profiles
  add column if not exists avatar_path   text,
  add column if not exists bio           text,
  add column if not exists quote         text,
  add column if not exists markets       text,
  add column if not exists trading_style text,
  add column if not exists location      text;

alter table public.profiles drop constraint if exists profiles_bio_len;
alter table public.profiles add  constraint profiles_bio_len     check (char_length(bio) <= 160);
alter table public.profiles drop constraint if exists profiles_quote_len;
alter table public.profiles add  constraint profiles_quote_len   check (char_length(quote) <= 80 and quote !~ E'[\\n\\r]');
alter table public.profiles drop constraint if exists profiles_markets_len;
alter table public.profiles add  constraint profiles_markets_len check (char_length(markets) <= 100);
alter table public.profiles drop constraint if exists profiles_style_len;
alter table public.profiles add  constraint profiles_style_len   check (char_length(trading_style) <= 30);
alter table public.profiles drop constraint if exists profiles_location_len;
alter table public.profiles add  constraint profiles_location_len check (char_length(location) <= 40);
-- A profile photo must live in the owner's own folder: nobody can point their profile at someone else's file.
alter table public.profiles drop constraint if exists profiles_avatar_own_folder;
alter table public.profiles add  constraint profiles_avatar_own_folder
  check (avatar_path is null or (left(avatar_path, 37) = id::text || '/' and char_length(avatar_path) <= 200 and position('..' in avatar_path) = 0));

-- You may edit only your own row (policy profiles_update, unchanged) and only these columns (never is_admin / id / created_at).
grant update (username, display_name, avatar_path, bio, quote, markets, trading_style, location) on public.profiles to authenticated;

notify pgrst, 'reload schema';
