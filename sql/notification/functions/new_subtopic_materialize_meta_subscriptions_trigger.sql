-- Creating a new concrete topic causes immediate subscriptions
-- for all those subscribed to the meta-topic.
create or replace function
    notification.new_subtopic_materialize_meta_subscriptions_trigger()
returns trigger
language plpgsql as
$$
    declare
        meta_topic_id_var int not null := topic_id
            from topic
            where
                category_id = NEW.category_id
                and is_general_category_topic;

    begin

        if meta_topic_id_var = NEW.topic_id
        then
            raise exception 'Wacky! This trigger should only fire'
                            ' for non-meta topic creation!';
        end if;

        -- materialize subscriptions for this new topic
        -- for all those subscribed to this topic's
        -- category's meta-topic.
        insert into notification.subscription
            (subscriber_id, topic_id, vector_id)
        select
            s.subscriber_id, NEW.topic_id, s.vector_id
        from notification.subscription s
        where s.topic_id = meta_topic_id_var;

        -- after trigger
        return null;
    end;
$$;
