# automodel

BigQuery automatic model rebuild based on r2 score deviation


To demo automodel usage in IOT use-cases we will need a stream of events on our PubSub topic. For this we will use `iot-event-maker`. The complete walkthrough the IOT Core registry and device setup is outline here: https://github.com/mchmarny/iot-event-maker

For purposes of `automodel` demo however we are going to simply run the one-time setup command and, assuming everything works, we will then run the event generation command which will send the mocked up events to our topic.

## Setup

To setup does two main things. It setup the GPC dependencies (Cloud PubSub topic, BitQuery table, Dataflow job), and configures IOT Core (Registry and Device). To execute the set up process run:

```shell
make setup
```



## Run

To stream mocked up events to the new IOT Core device run the `eventmaker` utility

Besides references to the IOT Core resources we created when you ran `make setup`, there are a few demo-specific parameters worth explaining:

* `--src` - Unique name of the device from which you are sending events. This is used to identify the specific sender of events in case you are running multiple clients. For this demo we will use something simple like `model-client`
* `--metric` - Name of the metric to generate that will be used as `label` in the sent event (e.g. `friction`)
* `--range` - Range of the random data points that will be generated for the above defined metric (e.g. `0.01-2.00` which means floats between `0.01` and `2.00`)
* `--freq` - Frequency in which these events will be sent to IoT Core (e.g. `2s` which means every 2 sec.)
*

```shell
./eventmaker --project=${GCP_PROJECT} --region=us-central1 --registry=automodel-reg \
		--device=automodel-device-1 --ca=root-ca.pem --key=device1-private.pem \
		--src=automodel-client --freq=2s --metric=utilization --range=0.01-2.00
```

After few lines of configuration output, you should see `eventmaker` posting to IOT Core

```shell
2019/05/12 14:43:26 Publishing: {"source_id":"demo-client","event_id":"eid-6ae3ab0d-a4d1-40a7-803c-f1e5158fe2b9","event_ts":"2019-05-12T21:43:26.303646Z","label":"my-metric","memFree":73.10791015625,"cpuFree":3500,"loadAvg1":2.65,"loadAvg5":2.88,"loadAvg15":3.46,"randomValue":1.2132739730794428}
```

The JSON payload in each one of these events looks something like this:

```json
{
    "source_id":"demo-client",
    "event_id":"eid-6ae3ab0d-a4d1-40a7-803c-f1e5158fe2b9",
    "event_ts":"2019-05-12T21:43:26.303646Z",
    "label":"my-metric",
    "memFree":73.10791015625,
    "cpuFree":3500,
    "loadAvg1":2.65,
    "loadAvg5":2.88,
    "loadAvg15":3.46,
    "randomValue":1.2132739730794428
}
```



## Model

### Create Model

In BigQuery query window run

```sql
#standardSQL
CREATE OR REPLACE MODEL automodel.friction_model
OPTIONS
  (model_type='linear_reg', input_label_cols=['metric']) AS
SELECT
  metric,
  label
FROM automodel.event
WHERE metric < 0.5
AND RAND() < 0.01
```

results in

```shell
This statement created a new model named automodel.friction_model
```


## Evaluate model

BigQuery model evaluation provides insight into the quality of the model. First we are going to create a table to store the model evaluation data

```shell
bq query --use_legacy_sql=false "
  CREATE OR REPLACE TABLE automodel.friction_model_eval (
   eval_ts TIMESTAMP NOT NULL,
   mean_absolute_error FLOAT64 NOT NULL,
   mean_squared_error FLOAT64 NOT NULL,
   mean_squared_log_error FLOAT64 NOT NULL,
   median_absolute_error FLOAT64 NOT NULL,
   r2_score FLOAT64 NOT NULL,
   explained_variance FLOAT64 NOT NULL
)"
```

Then we can crate BigQuery Scheduled job


```sql
#standardSQL
INSERT automodel.friction_model_eval (
   eval_ts,
   mean_absolute_error,
   mean_squared_error,
   mean_squared_log_error,
   median_absolute_error,
   r2_score,
   explained_variance
) WITH T AS (
  SELECT * FROM ML.EVALUATE(MODEL automodel.friction_model,(
        SELECT metric, label FROM automodel.event
  ))
)
SELECT
  CURRENT_TIMESTAMP(),
  mean_absolute_error,
  mean_squared_error,
  mean_squared_log_error,
  median_absolute_error,
  r2_score,
  explained_variance
FROM T
```

results in

```shell
mean_absolute_error	 mean_squared_error	 mean_squared_log_error	 median_absolute_error	r2_score            explained_variance
3.2502161606238453   227.0738450661901   0.008387276788977339    0.12880176496196327    0.9990422574648288  0.999079865551752
```

> The R2 score is a statistical measure that determines if the linear regression predictions approximate the actual data. 0 indicates that the model explains none of the variability of the response data around the mean. 1 indicates that the model explains all the variability of the response data around the mean.

# Use your model to predict stock price

```sql
#standardSQL
INSERT stocker.price_prediction (
   symbol,
   prediction_date,
   after_closing_price,
   predicted_price
) WITH T AS (

  SELECT
      dt.symbol as symbol,
      p.closingPrice as after_closing_price,
      ROUND(AVG(dt.predicted_price),2) as predicted_price
  FROM
    ML.PREDICT(MODEL stocker.price_model,
      (
      SELECT
        p.price,
        p.closingPrice as prev_price,
        c.symbol,
        c.magnitude * c.score as sentiment,
        CAST(c.retweet AS INT64) as retweet
      FROM stocker.content c
      JOIN stocker.price p on c.symbol = p.symbol
        AND FORMAT_TIMESTAMP('%Y-%m-%d', c.created) = FORMAT_TIMESTAMP('%Y-%m-%d', p.quotedAt)
  )) dt
  join stocker.price p on p.symbol =  dt.symbol
  where p.closingDate = FORMAT_TIMESTAMP('%Y-%m-%d', CURRENT_TIMESTAMP(), "America/Los_Angeles")
  group by
    dt.symbol,
    p.closingPrice

)
SELECT
   symbol,
   FORMAT_TIMESTAMP('%Y-%m-%d', CURRENT_TIMESTAMP(), "America/Los_Angeles"),
   after_closing_price,
   predicted_price
FROM T
```

## Predictions

```sql
SELECT
  symbol,
  prediction_date,
  after_closing_price,
  predicted_price
FROM stocker.price_prediction
group by
  symbol,
  prediction_date,
  after_closing_price,
  predicted_price
order by 1, 2
```

# Cleanup

To delete all the resources created on GCP during the `event` portion of this demo (topic, registry, and devices) run:

```shell
make cleanup
```