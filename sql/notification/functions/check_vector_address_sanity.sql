create or replace function notification.check_vector_address_sanity()
returns trigger language plpgsql
as $$
    declare
        like_pattern_var text not null := address_like_pattern
                from notification.vector where vector_id = NEW.vector_id;
    begin

        perform fail('address value does not conform to pattern '
                    || like_pattern_var)
        where
            not NEW.address like like_pattern_var;

        -- after trigger.
        return null;

    end;
$$;
