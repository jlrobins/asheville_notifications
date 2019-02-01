-- populate transmission table given any unqueued messages
-- whose send_on_or_after is in the past.

-- Returns the total count of message_transmission_queue records
-- created.
create or replace function
    notification.populate_message_transmission_queue()
returns int
language plpgsql
as $$
    declare
        message_row notification.message;
        count_inserted bigint not null := 0;
        total_inserted bigint not null := 0;
    begin
        -- foreach ready-to-send message not yet enqueued ...
        for message_row in select m.*
            from notification.message m
            where m.send_on <= now()
            and not exists (
                select 1 from message_transmission_queue mtq
                where mtq.message_id = m.message_id
                limit 1
            )
        loop

            insert into notification.message_transmission_queue
                (message_id, topic_id, subscriber_id, vector_id)
            select
                message_row.message_id, message_row.topic_id,
                    s.subscriber_id, s.vector_id
            from
                notification.subscription s
                    where topic_id = message_row.topic_id;

            -- columns enqueued and transmitted will have default values.

            get diagnostics count_inserted = row_count;
            total_inserted := total_inserted + count_inserted;

        end loop;

        return total_inserted;

    end;

$$;
