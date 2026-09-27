-- URDU ONLINE EXAM V4
-- Run this entire file once in Supabase SQL Editor.
-- This version keeps correct answers server-side and calculates the score in PostgreSQL.

create extension if not exists pgcrypto;

create table if not exists public.exams (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  code text not null unique,
  duration_seconds integer not null check (duration_seconds between 10 and 86400),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams(id) on delete cascade,
  question_order integer not null,
  question_text text not null,
  options jsonb not null check (jsonb_typeof(options)='array'),
  correct_index integer not null check (correct_index between 0 and 3)
);

create table if not exists public.attempts (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.exams(id) on delete cascade,
  student_name text not null,
  roll_number text not null,
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  score integer,
  total_questions integer,
  percentage numeric(6,2),
  auto_submitted boolean not null default false,
  unique(exam_id, roll_number)
);

create table if not exists public.answers (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.attempts(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete cascade,
  selected_index integer check (selected_index between 0 and 3),
  created_at timestamptz not null default now(),
  unique(attempt_id, question_id)
);

alter table public.exams enable row level security;
alter table public.questions enable row level security;
alter table public.attempts enable row level security;
alter table public.answers enable row level security;

-- Teacher policies
drop policy if exists "teacher exams select" on public.exams;
create policy "teacher exams select" on public.exams for select to authenticated
using ((select auth.uid()) = teacher_id);

drop policy if exists "teacher exams insert" on public.exams;
create policy "teacher exams insert" on public.exams for insert to authenticated
with check ((select auth.uid()) = teacher_id);

drop policy if exists "teacher exams update" on public.exams;
create policy "teacher exams update" on public.exams for update to authenticated
using ((select auth.uid()) = teacher_id)
with check ((select auth.uid()) = teacher_id);

drop policy if exists "teacher questions select" on public.questions;
create policy "teacher questions select" on public.questions for select to authenticated
using (exists(select 1 from public.exams e where e.id=questions.exam_id and e.teacher_id=(select auth.uid())));

drop policy if exists "teacher questions insert" on public.questions;
create policy "teacher questions insert" on public.questions for insert to authenticated
with check (exists(select 1 from public.exams e where e.id=questions.exam_id and e.teacher_id=(select auth.uid())));

drop policy if exists "teacher questions update" on public.questions;
create policy "teacher questions update" on public.questions for update to authenticated
using (exists(select 1 from public.exams e where e.id=questions.exam_id and e.teacher_id=(select auth.uid())))
with check (exists(select 1 from public.exams e where e.id=questions.exam_id and e.teacher_id=(select auth.uid())));

drop policy if exists "teacher questions delete" on public.questions;
create policy "teacher questions delete" on public.questions for delete to authenticated
using (exists(select 1 from public.exams e where e.id=questions.exam_id and e.teacher_id=(select auth.uid())));

drop policy if exists "teacher attempts select" on public.attempts;
create policy "teacher attempts select" on public.attempts for select to authenticated
using (exists(select 1 from public.exams e where e.id=attempts.exam_id and e.teacher_id=(select auth.uid())));

drop policy if exists "teacher answers select" on public.answers;
create policy "teacher answers select" on public.answers for select to authenticated
using (exists(
  select 1 from public.attempts a join public.exams e on e.id=a.exam_id
  where a.id=answers.attempt_id and e.teacher_id=(select auth.uid())
));

-- Students must use RPC functions; do not grant direct table access.
revoke all on public.exams, public.questions, public.attempts, public.answers from anon;
revoke all on public.exams, public.questions, public.attempts, public.answers from authenticated;

-- Secure RPC: start exam. It returns only question text/options, never correct_index.
create or replace function public.start_exam(p_code text, p_name text, p_roll text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  e public.exams;
  a public.attempts;
  q jsonb;
begin
  if length(trim(p_code)) < 1 or length(trim(p_name)) < 1 or length(trim(p_roll)) < 1 then
    raise exception 'Code, name and roll number are required';
  end if;

  select * into e from public.exams
  where upper(code)=upper(trim(p_code)) and active=true limit 1;

  if e.id is null then raise exception 'Exam not found or inactive'; end if;

  select * into a from public.attempts
  where exam_id=e.id and roll_number=trim(p_roll) limit 1;

  if a.id is not null then
    raise exception 'This Roll Number has already attempted this exam';
  end if;

  insert into public.attempts(exam_id,student_name,roll_number)
  values(e.id,trim(p_name),trim(p_roll))
  returning * into a;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',x.id,
      'question_text',x.question_text,
      'options',x.options
    ) order by random()
  ),'[]'::jsonb) into q
  from public.questions x where x.exam_id=e.id;

  return jsonb_build_object(
    'attempt',jsonb_build_object('id',a.id),
    'exam',jsonb_build_object('id',e.id,'title',e.title,'duration_seconds',e.duration_seconds),
    'questions',q
  );
end;
$$;

-- Secure RPC: score on server, enforce elapsed time, store answers once.
create or replace function public.submit_exam(
  p_attempt_id uuid,
  p_answers jsonb,
  p_auto_submitted boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  a public.attempts;
  e public.exams;
  q public.questions;
  item jsonb;
  selected integer;
  score integer := 0;
  total integer := 0;
  pct numeric(6,2);
  expired boolean;
begin
  select * into a from public.attempts where id=p_attempt_id for update;
  if a.id is null then raise exception 'Attempt not found'; end if;
  if a.submitted_at is not null then raise exception 'This attempt is already submitted'; end if;

  select * into e from public.exams where id=a.exam_id;
  expired := now() > a.started_at + make_interval(secs => e.duration_seconds);

  select count(*) into total from public.questions where exam_id=e.id;

  for item in select * from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb))
  loop
    selected := case when (item->>'selected_index') is null then null else (item->>'selected_index')::integer end;
    select * into q from public.questions where id=(item->>'question_id')::uuid and exam_id=e.id;
    if q.id is not null then
      insert into public.answers(attempt_id,question_id,selected_index)
      values(a.id,q.id,selected)
      on conflict(attempt_id,question_id) do update set selected_index=excluded.selected_index;
      if selected is not null and selected=q.correct_index then score := score+1; end if;
    end if;
  end loop;

  if total=0 then pct:=0; else pct:=round((score::numeric/total::numeric)*100,2); end if;

  update public.attempts
  set submitted_at=now(),score=score,total_questions=total,percentage=pct,
      auto_submitted=(p_auto_submitted or expired)
  where id=a.id;

  return jsonb_build_object(
    'score',score,'total_questions',total,'percentage',pct,
    'auto_submitted',(p_auto_submitted or expired)
  );
end;
$$;

-- RPC permissions: students may call only these two functions.
revoke all on function public.start_exam(text,text,text) from public, authenticated;
grant execute on function public.start_exam(text,text,text) to anon;

revoke all on function public.submit_exam(uuid,jsonb,boolean) from public, authenticated;
grant execute on function public.submit_exam(uuid,jsonb,boolean) to anon;
