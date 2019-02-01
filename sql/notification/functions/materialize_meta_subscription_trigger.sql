-- Suscribing to the 'meta' topic for a category cascades
-- to subscribing to all non-meta topics for said category.

-- Inverse of delete_meta_subscription_cascades_trigger.
create or replace function notification.materialize_meta_subscription_trigger()
returns trigger
language plpgsql as
$$
    declare
        category_row_var record;

    begin

        select * from notification.topic
            where topic_id = NEW.topic_id
            into category_row_var;

        -- If this is for a meta-topic, then
        -- expand it to all current concrete topics
        -- for said category.

        if category_row_var.is_general_category_topic
        then
            -- materialize subscriptions for all
            insert into notification.subscription
                (subscriber_id, topic_id, vector_id)
            select
                NEW.subscriber_id, t.topic_id, NEW.vector_id
            from notification.topic t
                where
                    -- non-meta topics ...
                    not is_general_category_topic
                    -- for this category ...
                    and category_id = category_row_var.category_id

                    -- not already subscribed to!
                    and not exists (
                        -- where not already subscribed
                        select 1
                        from notification.subscription
                        where
                            subscriber_id = NEW.subscriber_id
                            and topic_id = t.topic_id
                            and vector_id = NEW.vector_id
                    )
            ;

        end if;

        -- after trigger
        return null;
    end;
$$;
