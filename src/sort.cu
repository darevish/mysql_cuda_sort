#include <iostream>
#include <string>
#include <sstream>
#include <stdio.h>
#include <mysql.h>
#include <cstring>
#include <stdlib.h>
#include <sys/time.h>

#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/sort.h>

#include <boost/lexical_cast.hpp>

#include "../lib/inih/cpp/INIReader.h"

#include "QueryParser.hpp"

template <typename T>
class Sortable
{
  public:
    int originalIndex;
    T sortColumn;
    
    __host__ __device__ Sortable() {};
    
    Sortable(int _originalIndex, char* _sortColumn)
    {
      originalIndex = _originalIndex;
      sortColumn = boost::lexical_cast<T>(_sortColumn);
    }
};

template <typename TS>
class Sorter
{
  public:
    __host__ __device__ bool operator() (const Sortable<TS>& ls, const Sortable<TS>& rs) const
    {
      return ls.sortColumn < rs.sortColumn;
    }
};

void printElapsedTime(const timeval& stopTime, const timeval& startTime, const char* processorType)
{
  int elapsedSeconds = stopTime.tv_sec - startTime.tv_sec;
  double elapsedMilliSeconds;
  
  if (stopTime.tv_usec < startTime.tv_usec) {
    elapsedSeconds -= 1;
    elapsedMilliSeconds = (1000 + (stopTime.tv_usec / 1000)) - (startTime.tv_usec / 1000);
  } else {
    elapsedMilliSeconds = (stopTime.tv_usec / 1000) - (startTime.tv_usec / 1000);
  }
  
  double elapsedTime = elapsedSeconds + (elapsedMilliSeconds / 1000); 
  
  std::cout<<processorType<<" query execution and sorting took: "<<elapsedTime<<" seconds"<<std::endl;  
}

void verifyResult(const thrust::host_vector<MYSQL_ROW>& h_vec, int sortColumnIndex, const char* processorType)
{
  int errorCount = 0;
  for (int i = 0; i < h_vec.size(); i++) {
    if (i < (h_vec.size() - 2) && atoi(h_vec[i][sortColumnIndex]) > atoi(h_vec[i + 1][sortColumnIndex])) {
      std::cout<<"Error in "<<processorType<<" sorting at index "<<i<<". "<<h_vec[i][sortColumnIndex]<<" should be less than "<<h_vec[i + 1][sortColumnIndex]<<std::endl;
      errorCount++;
    }
  }
  std::cout<<"Errors: "<<errorCount<<std::endl;
}

template <typename TF>
void gpuSort(MYSQL *conn, std::string query, int sortColumnIndex)
{
  MYSQL_RES *result;
  MYSQL_ROW row;
  int num_fields;
  
  timeval startTime, stopTime;

  thrust::host_vector< Sortable<TF> > h_vec;

  thrust::host_vector<MYSQL_ROW> h_row_vec, h_row_vec_temp;
  
  gettimeofday(&startTime, NULL);
  
  mysql_query(conn, query.c_str());
  result = mysql_store_result(conn);

  num_fields = mysql_num_fields(result);
  if (num_fields <= sortColumnIndex) {
    std::cout<<"sortColumnIndex is greater than number of rows."<<std::endl;
    return;
  }

  int loopIndex = 0;
  while ((row = mysql_fetch_row(result)))
  {
    h_row_vec_temp.push_back(row);
    Sortable<TF> sortable(loopIndex, row[sortColumnIndex]);
    h_vec.push_back(sortable);
    loopIndex++;
  }
  
  thrust::device_vector< Sortable<TF> > d_vec = h_vec;
  
  thrust::sort(d_vec.begin(), d_vec.end(), Sorter<TF>());
  
  thrust::copy(d_vec.begin(), d_vec.end(), h_vec.begin());
  
  for (int i = 0; i < h_vec.size(); i++) {
    h_row_vec.push_back(h_row_vec_temp[h_vec[i].originalIndex]);
  }
  
  h_vec.clear();
  h_vec.shrink_to_fit();
  h_row_vec_temp.clear();
  h_row_vec_temp.shrink_to_fit();
  d_vec.clear();
  d_vec.shrink_to_fit();

  gettimeofday(&stopTime, NULL);
  
  verifyResult(h_row_vec, sortColumnIndex, "gpu");
  
  h_row_vec.clear();
  h_row_vec.shrink_to_fit();

  mysql_free_result(result);
  
  printElapsedTime(stopTime, startTime, "gpu");
}

void cpuSort(MYSQL *conn, std::string query, int sortColumnIndex)
{
  MYSQL_RES *result;
  MYSQL_ROW row;
//   int num_fields;
  
  timeval startTime, stopTime;

  thrust::host_vector<MYSQL_ROW> h_row_vec;
  
  gettimeofday(&startTime, NULL);
  
  mysql_query(conn, query.c_str());
  result = mysql_store_result(conn);

//   num_fields = mysql_num_fields(result);

  while ((row = mysql_fetch_row(result)))
  {
    h_row_vec.push_back(row);
  }
  
  gettimeofday(&stopTime, NULL);

  verifyResult(h_row_vec, sortColumnIndex, "cpu");

  h_row_vec.clear();
  h_row_vec.shrink_to_fit();

  mysql_free_result(result);
  
  printElapsedTime(stopTime, startTime, "cpu");
}

int main(int argc, char* argv[])
{
  char* tableName;
  
  if (argc <= 1 || argc > 2) {
    std::cout<<"Usage: "<<argv[0]<<" <table_name>"<<std::endl;
    return 1;
  }
  
  tableName = argv[1];

  INIReader iniReader("config/config.ini");
  if (iniReader.ParseError() < 0) {
      std::cout << "Can't load 'test.ini'\n";
      return 1;
  }
  
  const char *dbServer = iniReader.Get("database", "server", "localhost").c_str();
  const char *dbUser = iniReader.Get("database", "user", "root").c_str();
  const char *dbPassword = iniReader.Get("database", "password", "passwd").c_str();
  const char *dbDatabase = iniReader.Get("database", "database", "test").c_str();
  
  std::vector<std::string> queries;
  
  std::ostringstream queryBuilder;
  queryBuilder<<"SELECT SQL_NO_CACHE id, text_col, int_col, double_col FROM "<<tableName<<" ORDER BY int_col";
  queries.push_back(queryBuilder.str());
  queryBuilder.str("");
  queryBuilder<<"SELECT SQL_NO_CACHE id, text_col, int_col, double_col FROM "<<tableName<<" ORDER BY double_col";
  queries.push_back(queryBuilder.str());

  MYSQL *conn;
  conn = mysql_init(NULL);
  mysql_real_connect(conn, dbServer, dbUser, dbPassword, dbDatabase, 0, NULL, 0);

  for (int i = 0; i < queries.size(); i++) {
    QueryParserResult result = QueryParser::parse(queries[i], false, conn);

    std::cout<<"query: "<<result.getQuery()<<std::endl;

    if (result.getSortColumnType() == 3) {
      std::cout<<"calling gpuSort<int>"<<std::endl;
      gpuSort<int>(conn, result.getCroppedQuery(), result.getSortColumnNumber());
    } else if (result.getSortColumnType() == 5) {
      std::cout<<"calling gpuSort<double>"<<std::endl;
      gpuSort<double>(conn, result.getCroppedQuery(), result.getSortColumnNumber());
    }
    std::cout<<"calling cpuSort"<<std::endl;
    cpuSort(conn, result.getQuery(), result.getSortColumnNumber());
  }
  
  mysql_close(conn);
  
  return 0;
}
