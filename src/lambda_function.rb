# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'time'
require 'aws-sdk-dynamodb'
require 'aws-sdk-s3'

DYNAMODB_TABLE_NAME = ENV['DYNAMODB_TABLE_NAME']
S3_BUCKET_NAME = ENV['S3_BUCKET_NAME']
AUD_HOLDINGS = [50_601, 71_429]

def number_with_comma(number)
  integer_part = number.to_i.to_s
  integer_part.gsub(/(\d)(?=(\d{3})+(?!\d))/, '\\1,')
end

def lambda_handler(event:, context:)
  # Fetch AUD/JPY exchange rate
  rate = fetch_exchange_rate
  today = Time.now.strftime('%Y-%m-%d')

  # Save to DynamoDB
  save_to_dynamodb(date: today, rate: rate)

  # Generate and upload HTML graph
  rates = fetch_all_rates
  html = generate_html(rates)
  upload_to_s3(html)

  {
    statusCode: 200,
    body: JSON.generate({
      message: "Successfully updated AUD/JPY rate: #{rate} on #{today}"
    })
  }
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace.join("\n")
  {
    statusCode: 500,
    body: JSON.generate({ error: e.message })
  }
end

private

def fetch_exchange_rate
  uri = URI("https://api.frankfurter.dev/v1/latest?base=AUD&symbols=JPY")
  response = Net::HTTP.get_response(uri)

  unless response.is_a?(Net::HTTPSuccess)
    raise "Frankfurter API returned #{response.code}: #{response.body}"
  end

  data = JSON.parse(response.body)

  unless data['rates'] && data['rates']['JPY']
    raise "Frankfurter API error: JPY rate not found in response"
  end

  data['rates']['JPY'].to_f
end

def save_to_dynamodb(date:, rate:)
  dynamodb = Aws::DynamoDB::Client.new
  dynamodb.put_item(
    table_name: DYNAMODB_TABLE_NAME,
    item: {
      'date' => date,
      'rate' => rate,
      'currency_pair' => 'AUD/JPY',
      'updated_at' => Time.now.iso8601
    }
  )
end

def fetch_all_rates
  dynamodb = Aws::DynamoDB::Client.new
  items = []
  last_evaluated_key = nil

  loop do
    params = {
      table_name: DYNAMODB_TABLE_NAME,
      key_condition_expression: 'currency_pair = :pair',
      expression_attribute_values: {
        ':pair' => 'AUD/JPY'
      }
    }
    params[:exclusive_start_key] = last_evaluated_key if last_evaluated_key

    result = dynamodb.query(params)
    items.concat(result.items)
    last_evaluated_key = result.last_evaluated_key
    break unless last_evaluated_key
  end

  # Sort by date ascending
  items.sort_by { |item| item['date'] }
end

def generate_html(rates)
  dates = rates.map { |r| r['date'] }
  values = rates.map { |r| r['rate'].to_f }

  <<~HTML
    <!DOCTYPE html>
    <html lang="ja">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>AUD/JPY 為替レート推移</title>
      <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.7/dist/chart.umd.min.js"></script>
      <style>
        * {
          margin: 0;
          padding: 0;
          box-sizing: border-box;
        }
        body {
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
          background-color: #f5f5f5;
          padding: 20px;
        }
        .container {
          max-width: 1000px;
          margin: 0 auto;
          background: white;
          border-radius: 8px;
          box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
          padding: 30px;
        }
        h1 {
          text-align: center;
          color: #333;
          margin-bottom: 10px;
          font-size: 1.5rem;
        }
        .updated-at {
          text-align: center;
          color: #666;
          margin-bottom: 30px;
          font-size: 0.9rem;
        }
        .chart-container {
          position: relative;
          width: 100%;
          height: 400px;
        }
        .summary {
          margin-top: 20px;
          padding: 15px;
          background: #f9f9f9;
          border-radius: 4px;
          display: flex;
          justify-content: space-around;
          flex-wrap: wrap;
          gap: 10px;
        }
        .summary-item {
          text-align: center;
        }
        .summary-label {
          color: #666;
          font-size: 0.85rem;
        }
        .summary-value {
          color: #333;
          font-size: 1.2rem;
          font-weight: bold;
        }
      </style>
    </head>
    <body>
      <div class="container">
        <h1>AUD/JPY 為替レート推移</h1>
        <p class="updated-at">最終更新: #{Time.now.strftime('%Y年%m月%d日 %H:%M')} (JST)</p>
        <div class="chart-container">
          <canvas id="rateChart"></canvas>
        </div>
        <div class="summary">
          <div class="summary-item">
            <div class="summary-label">最新レート</div>
            <div class="summary-value" id="latestRate">#{values.last ? format('%.2f', values.last) : '-'} 円</div>
          </div>
          <div class="summary-item">
            <div class="summary-label">最高値</div>
            <div class="summary-value">#{values.any? ? format('%.2f', values.max) : '-'} 円</div>
          </div>
          <div class="summary-item">
            <div class="summary-label">最安値</div>
            <div class="summary-value">#{values.any? ? format('%.2f', values.min) : '-'} 円</div>
          </div>
          <div class="summary-item">
            <div class="summary-label">データ件数</div>
            <div class="summary-value">#{values.size} 日分</div>
          </div>
          #{AUD_HOLDINGS.map { |holding| <<~ITEM
          <div class="summary-item">
            <div class="summary-label">保有額 (#{number_with_comma(holding)} AUD)</div>
            <div class="summary-value">#{values.last ? number_with_comma(values.last * holding) : '-'} 円</div>
          </div>
          ITEM
          }.join}
        </div>
      </div>
      <script>
        const ctx = document.getElementById('rateChart').getContext('2d');
        new Chart(ctx, {
          type: 'line',
          data: {
            labels: #{JSON.generate(dates)},
            datasets: [{
              label: 'AUD/JPY',
              data: #{JSON.generate(values)},
              borderColor: '#2196F3',
              backgroundColor: 'rgba(33, 150, 243, 0.1)',
              borderWidth: 2,
              fill: true,
              tension: 0.1,
              pointRadius: 3,
              pointHoverRadius: 6
            }]
          },
          options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
              legend: {
                display: false
              },
              tooltip: {
                callbacks: {
                  label: function(context) {
                    return context.parsed.y.toFixed(2) + ' 円';
                  }
                }
              }
            },
            scales: {
              x: {
                display: true,
                title: {
                  display: true,
                  text: '日付'
                },
                ticks: {
                  maxTicksLimit: 10
                }
              },
              y: {
                display: true,
                title: {
                  display: true,
                  text: '円'
                }
              }
            }
          }
        });
      </script>
    </body>
    </html>
  HTML
end

def upload_to_s3(html)
  s3 = Aws::S3::Client.new
  s3.put_object(
    bucket: S3_BUCKET_NAME,
    key: 'index.html',
    body: html,
    content_type: 'text/html; charset=utf-8'
  )
end
