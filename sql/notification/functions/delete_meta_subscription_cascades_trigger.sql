-- unsuscribing from a 'meta' topic for a category cascades
-- to unsubscribing to all non-meta topics for said category.

-- Inverse of materialize_meta_subscription_trigger
create or replace function notification.delete_meta_subscription_cascades_trigger()
returns trigger
language plpgsql as
$$
    declare
        category_row_var record;
    begin

        select * from notification.topic
            where topic_id = OLD.topic_id
            into category_row_var;

        -- If this is for a meta-topic, then
        -- expand it to all current concrete topics
        -- for said category.

        if category_row_var.is_general_category_topic
        then
            -- de-materialize subscriptions for all
            delete from notification.subscription
            where
                subscriber_id = OLD.subscriber_id

                and vector_id = OLD.vector_id

                and topic_id in (
                    select t.topic_id
                    from notification.topic t
                    where category_id = category_row_var.category_id
                    and not is_general_category_topic
                );

        end if;

        -- after trigger
        return null;
    end;
$$;
