create or replace function public.fail(message text)
returns void language plpgsql
as $$
    begin
        raise exception '%', message;
    end;
$$;

/* trigger function for raising an exception with message
    passed as trigger argument 1. Useful when paired with
    invariants in the WHERE clause of the trigger statement. */
create or replace function public.fail_trigger()
returns trigger
language plpgsql as
$$
    begin
        raise exception '%', TG_ARGV[0];
    end;
$$;






