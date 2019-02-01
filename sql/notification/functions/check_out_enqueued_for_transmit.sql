create or replace function
notification.check_out_enqueued_for_transmit
        (vector_id_var vector_type, max_count_var int)
returns setof notification.message_transmission_queue
strict volatile
language sql as
$$

    -- select and lock in single pass ...
    with to_check_out as (
        select message_id, subscriber_id, vector_id
            from message_transmission_queue
            where
                transmitted is null
                and vector_id = vector_id_var
                and not locked
            order by enqueued
            limit max_count_var
            for update
    )

    update notification.message_transmission_queue mtq
        set locked = true
    from
        to_check_out as tco
    where
        mtq.message_id = tco.message_id
        and mtq.subscriber_id = tco.subscriber_id
        and mtq.vector_id = tco.vector_id
    -- return the set of locked records
    returning mtq.*;

$$;
