-- =====================================================================
-- TALLY COMMUNITY 2.0 MIGRATION: follows, For You ranking, Following feed
-- Additive only: no existing table, row, policy or function is changed.
-- Safe to re-run. Run once in the Supabase SQL editor (as postgres).
-- =====================================================================

-- 1. follows -----------------------------------------------------------
create table if not exists public.follows (
  follower_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  followed_id uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, followed_id),                        -- no duplicate follow relations
  constraint follows_not_self check (follower_id <> followed_id) -- nobody follows themselves
);
create index if not exists follows_followed_idx on public.follows (followed_id);  -- followers of X / the follow-check in feeds

alter table public.follows enable row level security;

drop policy if exists follows_select on public.follows;
create policy follows_select on public.follows for select to authenticated
  using (not public.is_blocked_pair((select auth.uid()), follower_id)
         and not public.is_blocked_pair((select auth.uid()), followed_id));

-- The follower is ALWAYS the signed-in user: the column is filled by its default (auth.uid()),
-- the client has no INSERT privilege on it, and the policy double-checks it.
drop policy if exists follows_insert on public.follows;
create policy follows_insert on public.follows for insert to authenticated
  with check (follower_id = (select auth.uid())
              and not public.is_blocked_pair((select auth.uid()), followed_id));

drop policy if exists follows_delete on public.follows;
create policy follows_delete on public.follows for delete to authenticated
  using (follower_id = (select auth.uid()));

revoke all on public.follows from anon, authenticated;
grant select, delete on public.follows to authenticated;
grant insert (followed_id) on public.follows to authenticated;

-- 2. Following feed: posts of accounts I follow (same columns as feed_posts) --------
create or replace view public.feed_following with (security_invoker = true) as
select fp.*
from public.feed_posts fp
where exists (
  select 1 from public.follows f
  where f.follower_id = (select auth.uid()) and f.followed_id = fp.author_id
);
revoke all on public.feed_following from anon, authenticated;
grant select on public.feed_following to authenticated;

-- 3. For You: explainable ranking, computed per category ---------------------------
--   score = (1 + likes + 2*comments) / (age_in_hours + 2) ^ 1.5      (time-decayed engagement; new posts get a base score)
--   x 1.3 when I follow the author, x 2 for my own post younger than 2 hours
--   x 0.6 for every further post of the same author (so nobody floods the feed)
-- p_asof is fixed by the client for one scroll session, so the order stays stable between pages.
create or replace function public.feed_for_you(
  p_kind text, p_limit int default 12, p_offset int default 0, p_asof timestamptz default now())
returns setof public.feed_posts
language sql stable security invoker set search_path = '' as $$
  with ranked as (
    select fp.id, fp.author_id, fp.kind, fp.title, fp.body, fp.payload, fp.image_paths, fp.created_at, fp.updated_at,
           fp.username, fp.display_name, fp.like_count, fp.comment_count,
           (1 + fp.like_count + 2 * fp.comment_count)::float8
             / power(greatest(extract(epoch from (p_asof - fp.created_at)) / 3600.0, 0) + 2, 1.5)
           * case when exists (select 1 from public.follows f
                               where f.follower_id = (select auth.uid()) and f.followed_id = fp.author_id) then 1.3 else 1 end
           * case when fp.author_id = (select auth.uid()) and fp.created_at > p_asof - interval '2 hours' then 2 else 1 end as s
    from public.feed_posts fp
    where fp.kind = p_kind and fp.created_at <= p_asof
  ), diversified as (
    select r.*, r.s * power(0.6, row_number() over (partition by r.author_id order by r.s desc, r.id desc) - 1) as ds
    from ranked r
  )
  select d.id, d.author_id, d.kind, d.title, d.body, d.payload, d.image_paths, d.created_at, d.updated_at,
         d.username, d.display_name, d.like_count, d.comment_count
  from diversified d
  order by d.ds desc, d.id desc
  limit least(greatest(p_limit, 1), 50) offset greatest(p_offset, 0)
$$;
revoke all on function public.feed_for_you(text, int, int, timestamptz) from public, anon;
grant execute on function public.feed_for_you(text, int, int, timestamptz) to authenticated;

notify pgrst, 'reload schema';
