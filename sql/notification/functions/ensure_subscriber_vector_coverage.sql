create or replace function
notification.ensure_subscriber_vector_coverage()
returns trigger language plpgsql as
$$
    begin
        perform fail('Expected at least one subscriber_vector row'
            ' for subscriber '|| NEW.subscriber_id)
        where not exists (
            select 1 from notification.subscriber_vector
            where subscriber_id = NEW.subscriber_id
        );

        -- after trigger
        return null;
    end;
$$;
