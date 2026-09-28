import time 
import os
import requests
import mysql.connector
import json
start_timer = time.perf_counter()


#--------------------------------------------------------------------------------------------------------------------
#General API connections, list inputs: (could have use fredapi lib which is much easier, but i like challenges)
#--------------------------------------------------------------------------------------------------------------------
# i used (setx FRED_API_KEY "actual api key") to be able to use it without mentioning it in the script itself

api_key = os.environ["FRED_API_KEY"]
connection = mysql.connector.connect(
    host="localhost",
    user=os.environ["MYSQL_USER"],
    password=os.environ["MYSQL_PASSWORD"]
)
# print(connection.is_connected())



BASE_URL = "https://api.stlouisfed.org/fred"
SERIES_LIST = [
    
    ("GDPC1",     "Real GDP (quarterly)"),
    ("CPILFESL",  "Core CPI"),
    ("WPSFD4131", "Core PPI (confirm title after loading)"),
    ("FEDFUNDS",  "Federal funds rate"),
    ("RSAFS",     "Retail sales"),
    ("UNRATE",    "Unemployment rate"),
    ("BOPGSTB",   "Trade balance"),
    ("UMCSENT",   "Consumer sentiment"),
    ("PAYEMS",    "Nonfarm payrolls"),
    
]

# ------------------------------------------------------------------
# Function: hide the key in any text we print
# ------------------------------------------------------------------
def hide_key(text):
    return str(text).replace(api_key, "***")



# ------------------------------------------------------------------
# Function: ask FRED for one endpoint, with up to 3 tries
# ------------------------------------------------------------------

def ask_fred(endpoint, series_id, tries = 3):
    
    url = f"{BASE_URL}/{endpoint}"
    parameteres = {
                "series_id" : series_id,
                "api_key" : api_key,
                "file_type" : "json"
                   }
    


    for attempt in range (1, tries+1):
        try : 
            response = requests.get(url, params=parameteres, timeout=30)
            response.raise_for_status()
            
            return response.json()
            
    
        except requests.RequestException as error:
            print(f"attempt {attempt} failed for {series_id} : {hide_key(error)}")
            
            if attempt == tries:
                raise 
            time.sleep(5)
            


# ------------------------------------------------------------------
# Loop: fetch details and data for each series, save both to bronze
# ------------------------------------------------------------------
loaded = 0
failed = 0
cursor = connection.cursor()

for series_id, note in SERIES_LIST:
    try: 
        meta = ask_fred("series", series_id)["seriess"][0] #FRED wraps the details in a list called seriess like (what it is, how often, in what units)
        data = ask_fred("series/observations", series_id) #values like (the dates and numbers)
        
        #1. Save the details
        cursor.execute(
            #The %s is a slot for any type of value, here we have 7 blank slots
            """
            INSERT INTO bronze.fred_raw_details (
                
                series_id, title, frequency, units, seasonal_adjust, observation_start, observation_end
                  
            )
            
            VALUES (%s, %s,%s, %s, %s, %s, %s)  
            """, 
            
            #These are the answers or data to fill each slot: 
           ( series_id, meta["title"], meta["frequency_short"], meta['units'], meta["seasonal_adjustment_short"], meta["observation_start"],
            meta["observation_end"])
            
        )
        
        
        #2. Save the numbers as one json package:
        
        cursor.execute(
            
            "INSERT INTO bronze.fred_raw (series_id, payload) VALUES (%s, %s)",
            (series_id, json.dumps(data)) # dictionary back to json text
        )
        
        
        connection.commit() # make both saves permanent
        
        
        loaded += 1
        
        print(f'{series_id}, {len(data["observations"])} rows | {meta["title"]}')
    #example : UNRATE,  944 rows, | Unemployement Rate
        
        
        
    except Exception as error: 
        connection.rollback() # undo if anything failed, good for data safety
        failed += 1
        
        print (f"FAILED {series_id}, {hide_key(error)}")
        
    
    time.sleep(0.3) #sleeps every while so we don't harm the FRED servers (being polite)



cursor.close()
connection.close()

print(f"Done: {loaded} loaded, {failed} failed")



end_timer = time.perf_counter()
delta_timer = end_timer - start_timer

print(f"This Process Took: {delta_timer:.2f}s")
