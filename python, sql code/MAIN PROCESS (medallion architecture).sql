# ------------------------------------------------------------------
#  Brief:
# ------------------------------------------------------------------
/* 
AN end-to-end project where we:

pull U.S economic data from API to database, apply medallion architecture where BRONZE is RAW data, SILVER is structured cleaned Data
And GOLD layer is the business ready analysis data, READY TO PLOT! 

GOAL: calculate a score that represent the US economy health based on a bunch of indicators in a quarterly basis
*/
# ------------------------------------------------------------------
#  DATABASES AND ACCESS
# ------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS bronze;
CREATE DATABASE IF NOT EXISTS silver;
CREATE DATABASE IF NOT EXISTS gold;

#The fred_loader account must exist before the GRANT statements
GRANT ALL PRIVILEGES ON bronze.* TO 'fred_loader'@'localhost';
GRANT ALL PRIVILEGES ON silver.* TO 'fred_loader'@'localhost';
GRANT ALL PRIVILEGES ON gold.*   TO 'fred_loader'@'localhost';

# ------------------------------------------------------------------
# BRONZE TABLE: raw data
# ------------------------------------------------------------------

#create bronze main table that's gonna hold raw data in a package 
CREATE TABLE IF NOT EXISTS bronze.fred_raw (
    id        INT AUTO_INCREMENT PRIMARY KEY,
    series_id VARCHAR(30),
    loaded_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    payload   JSON #going to be like this: [{"date": "1950-01-01", "value": "3.4"}, ......}]
    
    #why i imported them in a payload package? mainly for future adjustment and flexibility, 
    #so i can add any series from the python file without the need of changing anything in my table
);

#create bronze description table :
CREATE TABLE IF NOT EXISTS bronze.fred_raw_details (
    series_id         VARCHAR(30), #no need to create a primary key, fed_raw keeps the unique history
    loaded_at         DATETIME DEFAULT CURRENT_TIMESTAMP, #when did we download it?
    title             VARCHAR(255),
    frequency         VARCHAR(20),
    units             VARCHAR(100),
    seasonal_adjust   VARCHAR(50),
    observation_start DATE, # first date that the series covers 
    observation_end   DATE # last date that the series covers (for example: covers from 1980 to 2026)
);



CREATE TABLE IF NOT EXISTS silver.fred_observations (
    series_id VARCHAR(30),
    obs_date  DATE,
    value     DECIMAL(18,4),
    PRIMARY KEY (series_id, obs_date)
);



# ------------------------------------------------------------------
# SILVER TABLE: Unpack json, handle nulls and duplicates
# ------------------------------------------------------------------

TRUNCATE TABLE silver.fred_observations;   

INSERT INTO silver.fred_observations (series_id, obs_date, value)
SELECT 
	r.series_id,
    o.obs_date,
    CASE 
		WHEN o.raw_value = "." THEN NULL #fred uses "." to indicates Missing values
        
        ELSE CAST( o.raw_value AS DECIMAL(18, 4)) #otherewise convert o.raw_value to a real decimal, we didn't use float as it's an approximation
        #which is bad for money, and economics data
        
    END  #this case end statemnt will go to third postition which is values
 
 FROM bronze.fred_raw AS r
 JOIN (
	SELECT series_id, MAX(loaded_at) AS last_loaded
    FROM bronze.fred_raw 
    GROUP BY series_id
 ) AS latest
	
    ON r.series_id = latest.series_id
    AND r.loaded_at = latest.last_loaded #good practice to keep only the newest load of each series
    
   
JOIN json_table(r.payload,  # DOLLAR SIGN in '$.observations[*]', means starts at the root which is payload, then go into "observations"
		'$.observations[*]'  COLUMNS (
                            obs_date DATE 			PATH '$.date',
                            raw_value VARCHAR(30) 	PATH '$.value'
                            )
) AS o;
	
 
#"json_table" is mySQL function to turns a json list to a normal SQL table,

#payload col has json data like this, that's why we typed '$.observations[*]' , to unpack one row PER OBSERVATION list (hundreds of rows per series)
#and store each valuefrom the dictionary in a separate column
/*
"observations": [
        {
            "date": "1947-01-01",
            "value": "2182.681",
            "realtime_end": "2026-08-26",
            "realtime_start": "2026-08-26"
        },
        {
            "date": "1947-04-01",
            "value": "2176.892",
            "realtime_end": "2026-08-26",
            "realtime_start": "2026-08-26"
        },
 
*/
 
 
 
# ------------------------------------------------------------------
# SILVER TABLE: check data
# ------------------------------------------------------------------
 
 #check data: 
 SELECT o.series_id,
       COUNT(*)            AS data_points_count,
       MIN(o.obs_date)     AS silver_first,
       MAX(o.obs_date)     AS silver_last,
       r.observation_start AS fred_first,
       r.observation_end   AS fred_last,
       SUM(o.value IS NULL) AS missing_values
       
FROM silver.fred_observations o
JOIN bronze.fred_raw_details r
	ON o.series_id = r.series_id
    
GROUP BY o.series_id, r.observation_start, r.observation_end
ORDER BY o.series_id;


#we fixed structure by unpacking JSOn file, 
#we fixed data type of "value" column
#we handled duplicates using joins, we handled nulls and missing values using CASE WHEN, 
# we handled exact duplicates with that ( PRIMARY KEY (series_id, obs_date) ) when we created the silver table because primary keys are unique 
 

# ------------------------------------------------------------------
# GOLD TABLE: Schema (dim series, data_quarterly)
# ------------------------------------------------------------------
 
#let's turn these raw values get turned into something ready for analysis
#one row per indicator per QUARTER.

#ill addd small "dictionary" table describing each indicator (how to bucket it,
#whether higher is better, and how much it should weigh in the final score)

#STAR SCHEMA pattern:
#dim_series      = the "dimension" table (describes WHAT each indicator is)
#data_quarterly  = the "data" table (holds the actual numeric values)

#every fact row points back to exactly one dim_series row via series_key
#whcih means one row per indicator


#since gold database needs information about every indicator or series, we can store 
# these rules as data instead of hardcoding them into every query
#which means adding a new indiactor later , only needs adding one row here ,
#not rewriting the whole query , which helps in flexibility, and future adjustments


# ------------------------------------------------------------------
# GOLD TABLE:(dim series)
# ------------------------------------------------------------------
 
CREATE TABLE IF NOT EXISTS gold.dim_series(
	series_key INT AUTO_INCREMENT PRIMARY KEY,
    series_id VARCHAR (30) UNIQUE, #UNIQUE because each indicator mustappear exactly once in this table
	indicator_name VARCHAR (50), #the human readable forme, like "UNRATE" becomes "Unemployement RAte"
    
    bucket_rule VARCHAR (20), #we want to bucket to quarters so this tell us if "should this be averaged or summed when bucketed into a quarter?"
	
    month_expected TINYINT, #how many rows should exist per quarter, if it's already a quarter data like gdp then 1, if it's monthly like UNRATE then 3, and so on
    
    direction TINYINT, # "+1"  means we need higher values to count it as "good for economy" like GDP
				# while "-1" means we need less values to count it as "good or better for economy" like unemployement Rate
                
	weight DECIMAL (3,2)  #how much this indicator counts in the final score, relative to the others (so total is always 100%)
    #DECIMAL (3,2) means total numbers are 3 and we have 2 decimal point like 0.6 or 0.25
                                                           
);


TRUNCATE TABLE gold.dim_series;   -- empties it completely first

INSERT INTO gold.dim_series (series_id, indicator_name, bucket_rule, month_expected, direction, weight) #TOTAL weight must be 1 or 100%
VALUES 
	('GDPC1',     'Real GDP',                    'avg', 1, 1,  0.15), #already quarterly, so bucket_rule barely matters
    
    ('CPILFESL',  'Core CPI',                    'avg', 3, -1, 0.1), #inflation: treated as "lower is better" that's why direction is -1
    ('WPSFD4131', 'Core PPI (finished goods)',   'avg', 3, -1, 0.1),# inflation but from producer & sellers perspective not customer
	('FEDFUNDS',  'Federal funds rate',          'avg', 3, 0, 0.05),  # policy tool, ambiguous direction,so we will fix it in another query for readability
                                                                     
	('RSAFS',     'Retail sales',                'sum', 3, 1,  0.1),  #we count the sum of the 3 monthly totals
	('BOPGSTB',   'Trade balance',               'sum', 3, 1,  0.1),  #we count the sum of the 3 monthly totals
	('UMCSENT',   'Consumer sentiment',          'avg', 3, 1,  0.15),  #higher sentiment means moreoptimistic consumers
    
	('PAYEMS',    'Nonfarm payrolls',            'avg', 3, 1,  0.15),  #i have to count "YoY" rather than using raw value
    ('UNRATE',    'Unemployment rate',           'avg', 3, -1, 0.1);  #lower unemployment = healthier economy

 
 
#check total weight if its 1 (100%)
SELECT SUM(weight) AS total_weight FROM gold.dim_series;

# ------------------------------------------------------------------
# GOLD TABLE: set dynamic direction of FEDFUNDS based on CPI, PPI trends
# ------------------------------------------------------------------

UPDATE gold.dim_series
SET direction = (
	
    
    WITH monthly_trend AS (
		SELECT 
			series_id, 
            obs_date,
            value,
            
            #using LAG window function to compare the value of 3months ago
            LAG (value, 3) OVER(PARTITION BY series_id ORDER BY obs_date ASC) AS value_3m_ago
            
		FROM silver.fred_observations
        WHERE series_id IN ('WPSFD4131', 'CPILFESL')
		),
    
		
        latest_dates AS ( #-------------------------- this is called a chained CTE, we only use CTE keyword once on top for every query
			SELECT series_id, MAX(obs_date) AS latest_date
            FROM monthly_trend
            GROUP BY series_id
        ),
    
    
		latest_trend AS ( 
		SELECT 
			
							#cpi trend
			SUM(CASE  -- Each CASE contributes 1, -1, or 0, SUM combines the two rows values into one row
				WHEN t.series_id = 'CPILFESL' AND value > value_3m_ago THEN 1
                WHEN t.series_id = 'CPILFESL' AND value < value_3m_ago THEN -1
                ELSE 0
            END) AS cpi_trend,
            
							#ppi trend
                            
			SUM(CASE   
				WHEN t.series_id = 'WPSFD4131' AND value > value_3m_ago THEN 1
                WHEN t.series_id = 'WPSFD4131' AND value < value_3m_ago THEN -1
                ELSE 0
            END )AS ppi_trend
            
        # Were going to join monthly trend with latest_dates CTE to use last dates
        FROM monthly_trend AS t
        JOIN latest_dates AS d
			ON t.series_id =  d.series_id
			AND t.obs_date = d.latest_date #use date from monthly_trend that match the last date 
        
        #confirmation layer to take the latest value 
        
    )
    
    
    #now the moment of truth where we use out CTEs to set the direction
    
    SELECT 
		#If combined trend is positive (both or mostly rising), leads to rate hikes so direction is (+1), means more interest is beneficial for economy
		CASE 
			WHEN ( cpi_trend + ppi_trend ) > 0 THEN 1
            
		#If combined trend is negative (both or mostly falling), leads to rate cut so direction is (-11), means less interest is beneficial for economy
			WHEN ( cpi_trend + ppi_trend ) < 0 THEN -1
            
            ELSE 0 #when it's neutral then FEDFUNDS rate won't be included in overall score
        
        END 
        
	FROM latest_trend 
)


WHERE series_id = 'FEDFUNDS';



# ------------------------------------------------------------------
# GOLD TABLE: Schema (data_quarterly)
# ------------------------------------------------------------------
 
#One row per indicator per quarter, 
#that one row holds the quarterly value after we calculate the 3months value based on bucket rule
#some indicators stay as they're like GDP (already quarterly data)	

#Why ? this step is important becuase to compare and calculate the final score of economy health timestamp must be shared
 
 
 CREATE TABLE IF NOT EXISTS gold.data_quarterly (
	
    series_key INT, #foreign key to link it to "dim_series" table
    indicator_name VARCHAR(50) , 
    
    quarter_start DATE,             
    quarter_label VARCHAR(10), # for example: 2026-04-01 = Q2 2026
    value DECIMAL (18,3), #the value we get after we apply bucket rule (sum, avg, depending on each indicator)
    
    PRIMARY KEY (series_key, quarter_label)
    #composite key guarantee one value per indicator per quarter. just to avoid potential duplicates
 
 );
 
 
#logic :
/*
- every row from "silver.fred_observation", figure out which quarter it belongs to 
- combine that quarter's 3 months values using each series bucket rule
- only keep a quarter if it has the EXPECTED number of months present which is 3, so incomplete quarters won't appear

- i changed the whole logic, don't forget to re edit this later ------------------------------------------------------------------------- HERE

*/
 

TRUNCATE TABLE gold.data_quarterly;

INSERT INTO gold.data_quarterly (series_key, indicator_name, quarter_start, quarter_label, value)
SELECT 
		d.series_key,
		d.indicator_name,
        MAKEDATE(YEAR(o.obs_date), 1) 		+		INTERVAL (QUARTER(o.obs_date) - 1) QUARTER AS quarter_start,
			#MAKEDATE(YEAR(o.obs_date), 1) this will return first day of YEAR
			# INTERVAL (QUARTER(o.obs_date) - 1 >>> INTERVAL QUARTER of date, means add quarter to first dy of year,
            #for example :
            /*
				-o.obs_date = 2025-08-25
				-MAKEDATE(YEAR(o.obs_date), 1)
				gets the first day of the year: '2025-01-01'.
                
                 -QUARTER(o.obs_date) returns 3 because August is in Q3.
                 
                 -QUARTER(o.obs_date) -1 return 2 then we multiply it by INTERVAL of quarter "INTERVAL ...... QUARTER"
                 -so it becomes 3-1 which returns 2, multiplied by quarter interval so 2 * 3 = 6, 6MONTHS exactly
                 
                 - we add 6 months to the day of the year 2025-01-01 it becomes 2025-07-01 which is exactly the Q3 start
                 
                
            */
            
        
        
        
        CONCAT("Q", QUARTER(o.obs_date), " ", YEAR(o.obs_date)) AS quarter_label,
        # for example: 2026-04-01 = Q2 2026
        
        CASE 
			WHEN d.bucket_rule = "sum" THEN SUM(o.value)
            ELSE AVG(value) 
        END AS value


	FROM silver.fred_observations AS o
    JOIN gold.dim_series AS d
		ON o.series_id = d.series_id
        AND o.value IS NOT NULL
        #We join on gold.dim_series because the bucket rules to count the quarterly values are there
        
        
        
	GROUP BY d.series_key,d.indicator_name,quarter_start, quarter_label, d.bucket_rule, d.month_expected, YEAR(o.obs_date), QUARTER(o.obs_date)
    
    HAVING COUNT(*) = d.month_expected #this is so necessary so it bucket to quarter only when there's values of full 3 months not 1 or 2
    
    ORDER BY quarter_start DESC;



# ------------------------------------------------------------------
# GOLD TABLE: calculate Year over Year growth (data_quarterly_yoy_growth)
# ------------------------------------------------------------------


/*
Formula:
   YoY Growth % = ((Current Quarter - Quarter 1 Year Ago) / Quarter 1 Year Ago) * 100
   
   
Q1 2026 :22,000
Q1 2025 : 22,660

YoY growth = (22,000 - 22,660) / 22,660 * 100 >> -2.91%
*/



CREATE TABLE gold.data_quarterly_yoy_growth (

	series_key INT, #match series_key from "data_quarterly" and "dim_series" tables
	indicator_name VARCHAR(50),
    
    quarter_start DATE, #sometimes there's incomplete quarters so its useful, also it's good to use in ORDER BY
    quarter_label VARCHAR(10) ,
    
    yoy_growth_rate DECIMAL (7, 2), # year over year growth percentage
    
    PRIMARY KEY (series_key, quarter_start)

);


TRUNCATE TABLE gold.data_quarterly_yoy_growth;




INSERT INTO gold.data_quarterly_yoy_growth (series_key, indicator_name, quarter_start, quarter_label, yoy_growth_rate)
WITH lagged_data AS 
(
	SELECT
		series_key,
        quarter_start,
        LAG (value, 4) OVER(PARTITION BY series_key ORDER BY quarter_start) AS last_year_value
        
	FROM gold.data_quarterly
        
)

	SELECT 
		q.series_key,
        q.indicator_name,
        q.quarter_start,
        q.quarter_label,
        
        ROUND((q.value - l.last_year_value) / NULLIF(l.last_year_value, 0) * 100, 2) AS yoy_growth_rate
										#used NULLIF because we can't devide on 0
	
        
    
    
    FROM gold.data_quarterly AS q
    JOIN lagged_data AS l
		ON q.series_key = l.series_key
        AND q.quarter_start = l.quarter_start
        
    ORDER BY q.quarter_start DESC;





# ------------------------------------------------------------------
# GOLD TABLE: economic health scoring (economy_score)
# ------------------------------------------------------------------

#each indicator scores it's full weight if (direction * yoy growth) > 0
 #example of scoring : 
 /*
Real GDP 					yoy growth: +0.2%, direction is +1, growth is positive too, weight is 0.15 // +15%
Core CPI					yoy growth: +1.5%, direction is -1, growth is positive, weight is 0.15 	// +0%
Core PPI (finished goods) 	yoy growth: +1%, direction is -1, growth is positive, weight is 0.15 	// +0%

Federal funds rate			yoy growth: +0.5%, since both inflation indicators (cpi, ppi) are positive then direction is +1 and growth is positive, weight is 0.05 // +5%
Retail sales				yoy growth: +2%, direction is +1, growth is positive too, weight is 0.10 // +10%

Trade balance				yoy growth: -0.1%, direction is +1, growth is negative, weight is 0.1 // 0%
Consumer sentiment			yoy growth: -0.5%, direction is +1, growth is negative, weight is 0.15 // 0%
Nonfarm payrolls			yoy growth: 0%, 														// 0%
Unemployment rate			yoy growth: 0.2%, direction is -1, growth is positive, weight is 0.15 // 0%
 
 SCORE : 40% or 4/10 which is BAD
 */
 
 
 CREATE TABLE gold.economy_score 
 (

	 quarter_start DATE, #helps in sorting
     quarter_label VARCHAR(10) ,
     economic_score DECIMAL (5, 2) ,#0.00 to 100.00 SCORE
     
     indicator_used TINYINT, #how manny indicators used to calculate that quarter's score
     
     PRIMARY KEY (quarter_start) #duplicates protection
 
 );
 
TRUNCATE TABLE gold.economy_score;


INSERT INTO gold.economy_score ( quarter_start, quarter_label, economic_score, indicator_used)

WITH indicator_contribution AS 
(
	#for every quarter, we decide if the indicator will be counted in final score if it passes and assigned a score of it's own weight
    #this formula (direction * yoy growthRate) > 0
    
    SELECT 
		g.quarter_start,
        g.quarter_label,
        g.yoy_growth_rate,
        
        CASE 
			WHEN (d.direction * g.yoy_growth_rate) > 0 THEN d.weight 
			ELSE 0
        
        END AS score
    

    FROM gold.data_quarterly_yoy_growth g
    JOIN gold.dim_series d #we join this table to get the direction
    
		ON g.series_key = d.series_key
)

SELECT 	
	quarter_start, 
    quarter_label,
    
    ROUND(SUM(score) * 100, 2) AS economic_score,
    
    COUNT(*) AS indicator_used

FROM indicator_contribution
GROUP BY quarter_start, quarter_label

ORDER BY quarter_start DESC;



# ------------------------------------------------------------------
# CHECK RESULTS
# ------------------------------------------------------------------

SELECT * FROM gold.economy_score;







