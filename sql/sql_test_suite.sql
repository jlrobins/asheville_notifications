-- SQL-level basic "test suite"

-- Real project would have this in, say, python unit tests or whatnot.
-- (but let's be masochists and do this just depending on postgresql/psql)

-- Currently invoked within main schema TX, so no major TX boundaries here.
-- We do use a savepoint so as to be able to have each 'test' be its
-- own sub-transaction for easy cleanup and isolation.

\set ON_ERROR_STOP 1
set search_path = notification, public;


begin;

/*
    SQL-level test suite convienence function.
    Perform this statement and expect it to raise an exception.
    If it doesn't, then actually raise an exception.

    If exception_message_prefix_var is provided, then
    if the raised exception's message doesn't start with
    this text, then raise a might exception.
*/

create function public.expect_fail(stmt text,
                    exception_message_prefix_var text = null)
returns void
language plpgsql as
$$
  declare
    raised_var boolean;
    exception_message_var text;
  begin

    begin
      execute stmt;
      raised_var := false; -- D'oh!
    exception
      -- matches every error type except QUERY_CANCELED and ASSERT_FAILURE.
      when others then
        raised_var := true;

        if exception_message_prefix_var is not null
        then
          get stacked diagnostics exception_message_var := message_text;

          if not exception_message_var ilike (exception_message_prefix_var || '%')
          then
            raise exception 'Exception message "%" does not start with "%"',
                      exception_message_var, exception_message_prefix_var;
          end if;
        end if;

    end;

    if not raised_var
    then
      raise exception
        'Expected to catch an exception but did not when performing %', stmt;
    end if;

  end;
$$;


SAVEPOINT original_state;

do $body$
  declare
    topic_id_var int;
  begin

    insert into topic (category_id, subject, description)
      values ('CONSTRUCTION_PROJECT', 'Our first project!',
                                      'Build those buildings!')
      returning topic_id into topic_id_var;

    -- changing category_id of a topic not allowed
    perform expect_fail(
      'update topic set category_id = ''BOND_PACKAGE'' where topic_id = '
             || topic_id_var
    );

    -- but changing subject or description is A-OK ...
    update topic
      set subject = 'test',
        description = 'test description'
      where
        topic_id = topic_id_var;

    -- deleting this non-is_general_category_topic is A-OK
    delete from topic where topic_id = topic_id_var;

  end;
$body$;

rollback to original_state;

do $body$
  begin
    -- deleting a is_general_category_topic topic not allowed
    -- since it uncovers the category ...
    delete from topic where category_id = 'BOND_PACKAGE'
        and is_general_category_topic;

    -- (exception won't happen until commit or when we force
    -- the trigger to fire, usually at COMMIT, but we can
    -- coax it via pulling the constraints to fire immediately, draining
    -- the queue.)
    perform expect_fail(
      'set constraints all immediate'
    );

  end;
$body$;

rollback to original_state;


-- test message + required bodypart vector / mimetypes
do $$
  declare
    message_id_var int;
    topic_id_var int not null :=
      topic_id from topic where category_id = 'BOND_PACKAGE'
      and is_general_category_topic;
  begin

    -- New message!
    insert into message (topic_id, send_on, title)
        values (2, now(), 'New Bonds Granted')
    returning message_id into message_id_var;

    -- should fail 'cause no message_bodyparts at all.
    perform expect_fail(
      'set constraints all immediate'
    );

    insert into message_bodypart (message_id, vector_id, mimetype, body)
      values (message_id_var, 'EMAIL', 'text/plain',
              'Yay, we can has bonds!');

    -- should fail 'cause also need a 'text/html' mimetype message_bodypart.
    perform expect_fail(
      'set constraints all immediate'
    );

    -- now all happy.
    insert into message_bodypart (message_id, vector_id, mimetype, body)
      values (message_id_var, 'EMAIL', 'text/html',
                        '<h1>Yay, we can has bonds!</h1>');

    -- should now work.
    set constraints all immediate;
  end;
$$;

rollback to original_state;

-- Excercise subscriber_vector invalid address
do
$b$
  declare
    subscriber_id_var int;
    stmt text;
  begin

  insert into subscriber (fullname)
      values ('Frank Zappa')
      returning subscriber_id into subscriber_id_var;

      -- Interpolate subscriber_id_var into the values section
      -- as a literal. Grumble.
      stmt := format($$
            insert into subscriber_vector
              (subscriber_id, vector_id, address)
            values (%s, 'EMAIL', 'mother.invention.com')
        $$, subscriber_id_var);

    perform expect_fail(stmt, 'address value does not conform');

  end;
$b$;

rollback to original_state;


-- test subscriptions to base topics as well as meta-topics
-- to see sub-topic subscriptions happen as expected,
-- as well as all swept away when unsubscribed from meta-topic.
do $$
  declare
    meta_topic_id_var int := topic_id from topic
                                where category_id = 'BOND_PACKAGE';
    subscriber_id_var int;
    subtopic_id_var int;
    second_subtopic_id_var int;
  begin

    insert into subscriber (fullname)
      values ('Frank Zappa')
      returning subscriber_id into subscriber_id_var;

    insert into subscriber_vector (subscriber_id, vector_id, address)
        values (subscriber_id_var, 'EMAIL', 'mother@invention.com');

    insert into topic (category_id, subject, description)
      values ('BOND_PACKAGE', 'Freak Out Bonds',
                'City voters decided to fund another round of freak outs!')
      returning topic_id into subtopic_id_var;

    -- Frank wants updates on all bond notifications.
    insert into subscription
      (subscriber_id, topic_id, vector_id)
    values
      (subscriber_id_var, meta_topic_id_var, 'EMAIL');

    perform fail('expected to also see a subscription to topic '
                        || subtopic_id_var)
    from
      subscription
      where subscriber_id = subscriber_id_var
          and topic_id = subtopic_id_var
          and vector_id = 'EMAIL'
    having count(*) = 0;

    -- Create nother bond topic ...
    insert into topic (category_id, subject, description)
      values ('BOND_PACKAGE', 'Inca Roads Bonds',
                  'Help the aliens drive down Machu Picchu.')
      returning topic_id into second_subtopic_id_var;

    -- ... and Frank better be auto-subscribed.
    perform fail('expected to see a subscription to topic '
                  || second_subtopic_id_var)
    from
      subscription
      where subscriber_id = subscriber_id_var
      and topic_id = second_subtopic_id_var
      and vector_id = 'EMAIL'
    having count(*) = 0;

    -- Unsubscription from a meta-topic auto cascades to all subtopics.
    delete from subscription
        where subscriber_id = subscriber_id_var
        and topic_id = meta_topic_id_var;

    perform fail('expected to have no subscriptions at all, but '
                               || count(*) || ' remaining!')
    from
      subscription
      where subscriber_id = subscriber_id_var
    having count(*) > 0;

  end;
$$;
rollback to original_state;


-- Tests over populate_message_transmission_queue
do $$
  declare
    meta_topic_id_var int := topic_id from topic
              where category_id = 'BOND_PACKAGE';
    subscriber_id_var int;
    another_subscriber_id_var int;
    topic_id_var int;
    message_id_var int;
    created_count_var int;
  begin

    insert into subscriber (fullname)
      values ('Frank Zappa')
      returning subscriber_id into subscriber_id_var;

    insert into subscriber_vector (subscriber_id, vector_id, address)
        values (subscriber_id_var, 'EMAIL', 'mother@invention.com');

    insert into subscriber (fullname)
      values ('Jimi Hendrix')
      returning subscriber_id into another_subscriber_id_var;

    perform expect_fail('set constraints all immediate',
            'Expected at least one subscriber_vector row for subscriber');

    insert into subscriber_vector (subscriber_id, vector_id, address)
        values (another_subscriber_id_var, 'EMAIL',
                        'if6was9@electricladyland.com');


    insert into topic (category_id, subject, description)
      values ('BOND_PACKAGE', 'Freak Out Bonds',
                'City voters decided to fund another round of freak outs!')
      returning topic_id into topic_id_var;

    -- Frank wants updates on all bond notifications.
    -- Jimi has not subscribed to *any* notifications yet, so should
    -- not get any messages ...
    insert into subscription
      (subscriber_id, topic_id, vector_id)
    values
      (subscriber_id_var, meta_topic_id_var, 'EMAIL');

    -- Let's make a 'Freak Out Bonds' message
    insert into message (topic_id, title)
        values (topic_id_var, 'New Bond Announcement')
        returning message_id into message_id_var;

    -- trying to make it sendable now should fail, not enough message_bodyparts.
    update message set send_on = now() where message_id = message_id_var;
    perform expect_fail('set constraints all immediate',
        'Need a message_bodypart row for vector EMAIL and mimetype text/plain');

    -- put back to not ready yet for now.
    update message set send_on = null where message_id = message_id_var;

    insert into message_bodypart (message_id, vector_id, mimetype, body)
      values
          (message_id_var, 'EMAIL', 'text/plain',
                  'Ready to Freak Out?\nVoters approved new bond package'
                  ' for monies allowing purchase of all MOI albums!'),
          (message_id_var, 'EMAIL', 'text/html',
                  '<h1>Ready to Freak Out?</h1>'
                  '<p>Voters approved new bond package'
                  ' for monies allowing purchase of all MOI albums!</p>')
    ;

    -- Now ready!
    update message set send_on = now() where message_id = message_id_var;
    set constraints all immediate; -- should now pass.

    select populate_message_transmission_queue() into created_count_var;

    perform fail('Expected one generated message!')
    where created_count_var != 1; -- better not have hit jimi too!

    perform fail('Expected to find exactly one perfectly generated message!')
    from message_transmission_queue
      where topic_id = topic_id_var
        and message_id = message_id_var
        and subscriber_id = subscriber_id_var
        and vector_id = 'EMAIL'
        and enqueued = now()
        and transmitted is null
    having count(*) != 1
    ;

  end;
$$;
rollback to original_state;

rollback;




